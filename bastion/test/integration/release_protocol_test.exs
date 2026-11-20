if beam_root = System.get_env("RELEASE_AGENT_BEAM_ROOT") do
  for beam_dir <- Path.wildcard(Path.join(beam_root, "*/ebin")), do: Code.prepend_path(beam_dir)
end

if System.get_env("RELEASE_PROTOCOL_INTEGRATION") == "1" and
     Code.ensure_loaded?(DelivestAgent.Bastion) do
  defmodule Bastion.ReleaseProtocolIntegrationTest do
    use BastionWeb.ChannelCase, async: false
    use Slipstream.SocketTest

    import Bastion.Fixtures

    alias Bastion.{Instances, Releases}
    alias BastionWeb.AgentSocket
    alias DelivestAgent.{Bastion, ComposeStub, FakeRunner, Release}

    @moduletag :tmp_dir

    setup %{tmp_dir: dir} do
      keys = [
        :data_dir,
        :bastion_test_mode,
        :hosts,
        :gateway_url,
        :runner,
        :health_timeout_ms,
        :health_poll_ms,
        :pull_retry_delays_ms,
        FakeRunner
      ]

      previous = for key <- keys, do: {key, Application.fetch_env(:delivest_agent, key)}

      Application.put_env(:delivest_agent, :data_dir, dir)
      Application.put_env(:delivest_agent, :bastion_test_mode, true)
      Application.put_env(:delivest_agent, :runner, FakeRunner)
      Application.put_env(:delivest_agent, :health_timeout_ms, 1_000)
      Application.put_env(:delivest_agent, :health_poll_ms, 10)
      Application.put_env(:delivest_agent, :pull_retry_delays_ms, [0, 0])

      Application.put_env(:delivest_agent, :hosts, %{
        "api" => "api.example.com",
        "site" => "site.example.com"
      })

      Application.put_env(:delivest_agent, :gateway_url, serve_site())

      on_exit(fn ->
        for {key, value} <- previous do
          case value do
            {:ok, value} -> Application.put_env(:delivest_agent, key, value)
            :error -> Application.delete_env(:delivest_agent, key)
          end
        end
      end)

      start_supervised!({Task.Supervisor, name: DelivestAgent.TaskSupervisor})
      %{dir: dir}
    end

    test "two agents install cached X on both sides of X+1 and retry keeps the same ID", %{
      dir: dir
    } do
      x = release_fixture("1.2.3")
      selected_runner(dir, x)

      agent =
        start_supervised!(
          {Bastion, %{url: "wss://bastion.example.com", token: "test-agent-token"}}
        )

      id = File.read!(Path.join(dir, "instance_id"))
      topic = "instance:" <> id

      Slipstream.SocketTest.accept_connect(agent)
      Slipstream.SocketTest.assert_join(^topic, info, :ok)
      assert info["capabilities"] == ["release_manifest_v1"]

      {:ok, server} = connect(AgentSocket, %{"token" => "test-agent-token", "instance_id" => id})
      {:ok, _, server} = subscribe_and_join(server, topic, info)
      Slipstream.SocketTest.assert_push(^topic, "heartbeat", heartbeat)
      ref = Phoenix.ChannelTest.push(server, "heartbeat", heartbeat)
      assert_reply ref, :ok

      # The operator pins X after X+1 is already cached. The wire command keeps X's digest.
      assert {:ok, %{manifest: ^x}} = Releases.resolve("1.2.3")

      {:ok, command} =
        Instances.send_command(Instances.get_instance(id), "update", %{"release" => x})

      command_id = command.id
      assert_push "command", payload
      assert payload == %{"id" => command_id, "action" => "update", "args" => %{"release" => x}}

      Slipstream.SocketTest.push(agent, topic, "command", payload)
      Slipstream.SocketTest.assert_push(^topic, "command_started", %{"id" => ^command_id})
      ref = Phoenix.ChannelTest.push(server, "command_started", %{"id" => command_id})
      assert_reply ref, :ok

      Slipstream.SocketTest.assert_push(^topic, "command_result", result, _, 30_000)
      assert result["id"] == command_id
      assert result["ok"] == true, inspect(result)
      assert Release.rollback_info()["current"]["digest"] == x["images"]

      # Lose the first result, then reconnect the Bastion channel. It replays the pending ID.
      {:ok, new_server} =
        connect(AgentSocket, %{"token" => "test-agent-token", "instance_id" => id})

      {:ok, _, new_server} = subscribe_and_join(new_server, topic, info)
      assert_push "command", ^payload
      Slipstream.SocketTest.assert_push(^topic, "heartbeat", current_status, _, 5_000)
      ref = Phoenix.ChannelTest.push(new_server, "heartbeat", current_status)
      assert_reply ref, :ok
      drain_commands()
      Slipstream.SocketTest.push(agent, topic, "command", payload)
      Slipstream.SocketTest.assert_push(^topic, "command_result", repeated, _, 5_000)
      assert repeated["id"] == command_id
      assert repeated["ok"] == true
      ref = Phoenix.ChannelTest.push(new_server, "command_result", repeated)
      assert_reply ref, :ok
      assert [%{status: "ok", args: %{"release" => ^x}}] = Instances.list_commands(id)
      refute_receive {:cmd, "docker", ["pull" | _]}, 50

      # X+1 becomes available. A different restaurant still receives exactly X.
      release_fixture("1.2.4")
      stop_supervised(Bastion)
      second_dir = Path.join(dir, "second")
      File.mkdir_p!(second_dir)
      Application.put_env(:delivest_agent, :data_dir, second_dir)
      selected_runner(second_dir, x)

      second_agent =
        start_supervised!(
          {Bastion, %{url: "wss://bastion.example.com", token: "test-agent-token"}}
        )

      second_id = File.read!(Path.join(second_dir, "instance_id"))
      second_topic = "instance:" <> second_id
      refute second_id == id

      Slipstream.SocketTest.accept_connect(second_agent)
      Slipstream.SocketTest.assert_join(^second_topic, second_info, :ok)

      {:ok, second_server} =
        connect(AgentSocket, %{"token" => "test-agent-token", "instance_id" => second_id})

      {:ok, _, second_server} = subscribe_and_join(second_server, second_topic, second_info)
      Slipstream.SocketTest.assert_push(^second_topic, "heartbeat", second_heartbeat, _, 5_000)
      ref = Phoenix.ChannelTest.push(second_server, "heartbeat", second_heartbeat)
      assert_reply ref, :ok

      {:ok, second_command} =
        Instances.send_command(Instances.get_instance(second_id), "update", %{"release" => x})

      second_command_id = second_command.id
      assert_push "command", second_payload
      assert second_payload["id"] == second_command_id
      assert second_payload["args"]["release"]["images"] == x["images"]
      Slipstream.SocketTest.push(second_agent, second_topic, "command", second_payload)

      Slipstream.SocketTest.assert_push(^second_topic, "command_started", %{
        "id" => ^second_command_id
      })

      ref =
        Phoenix.ChannelTest.push(second_server, "command_started", %{"id" => second_command_id})

      assert_reply ref, :ok
      Slipstream.SocketTest.assert_push(^second_topic, "command_result", second_result, _, 30_000)
      assert second_result["ok"] == true, inspect(second_result)
      ref = Phoenix.ChannelTest.push(second_server, "command_result", second_result)
      assert_reply ref, :ok
      assert Release.rollback_info()["current"]["digest"] == x["images"]
      assert [%{status: "ok", args: %{"release" => ^x}}] = Instances.list_commands(second_id)
    end

    defp drain_commands do
      receive do
        {:cmd, _, _} -> drain_commands()
      after
        0 -> :ok
      end
    end

    defp selected_runner(dir, manifest) do
      File.mkdir!(Path.join(dir, ".git"))

      git = fn _command, args ->
        cond do
          "get-url" in args ->
            {"https://github.com/ShafranovKirill/delivest.git\n", 0}

          "ls-tree" in args ->
            {Enum.map_join(
               ~w(server client agent),
               "\n",
               &"160000 commit #{manifest["gitlinks"][&1]}\t#{&1}"
             ) <> "\n", 0}

          true ->
            {"done\n", 0}
        end
      end

      config = fn _command, _args ->
        {body, 0} = ComposeStub.default_response(:config_json, dir, [])
        services = Jason.decode!(body)["services"]

        env =
          File.read(Path.join(dir, ".env"))
          |> then(fn
            {:ok, text} -> text
            _ -> ""
          end)

        services =
          Enum.reduce(~w(server client), services, fn component, acc ->
            key = "DELIVEST_#{String.upcase(component)}_IMAGE="

            ref =
              Enum.find_value(String.split(env, "\n"), fn line ->
                if String.starts_with?(line, key),
                  do: String.replace_prefix(line, key, ""),
                  else: nil
              end)

            if ref, do: put_in(acc, [component, "image"], ref), else: acc
          end)

        {Jason.encode!(%{"services" => services}), 0}
      end

      image_inspect = fn _command, args ->
        ref = List.last(args)

        if String.starts_with?(ref, "ghcr.io/shafranovkirill/delivest-client@") do
          format = args |> Enum.drop_while(&(&1 != "--format")) |> Enum.at(1) || ""

          if String.contains?(format, "version"),
            do: {"sha256:444|2.0.0\n", 0},
            else: {"sha256:444\n", 0}
        else
          ComposeStub.default_response(:image_inspect, dir, args)
        end
      end

      FakeRunner.stub_global(
        ComposeStub.runner(self(), dir, %{
          git: git,
          config_json: config,
          image_inspect: image_inspect
        })
      )
    end

    defp serve_site do
      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, port} = :inet.port(listen)
      spawn_link(fn -> accept(listen) end)
      "http://127.0.0.1:#{port}"
    end

    defp accept(listen) do
      case :gen_tcp.accept(listen) do
        {:ok, conn} ->
          {:ok, request} = :gen_tcp.recv(conn, 0, 2_000)

          body =
            if request =~ ~r/^GET \/ready /i,
              do: Jason.encode!(%{"status" => "ok", "app" => "delivest", "version" => "1.1.0"}),
              else: ~s(<div id="app"></div>)

          :gen_tcp.send(
            conn,
            "HTTP/1.1 200 OK\r\ncontent-length: #{byte_size(body)}\r\nconnection: close\r\n\r\n" <>
              body
          )

          :gen_tcp.close(conn)
          accept(listen)

        _ ->
          :ok
      end
    end
  end
end
