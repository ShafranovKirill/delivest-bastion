defmodule Bastion.ChecksTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.Checks.{External, Worker}
  alias Bastion.Instances

  setup do
    on_exit(fn ->
      Application.delete_env(:bastion, :telegram_chat_id)
      Application.put_env(:bastion, :telegram_bot_token, nil)
    end)
  end

  defp stub(fun), do: Req.Test.stub(Bastion.Http, fun)

  test "external checks request every public host" do
    stub(fn conn ->
      case conn.host do
        "api.example.com" -> Plug.Conn.send_resp(conn, 200, "ok")
        "site.example.com" -> Plug.Conn.send_resp(conn, 503, "down")
      end
    end)

    assert %{
             "api" => %{"ok" => true, "status" => 200},
             "site" => %{"ok" => false, "status" => 503}
           } =
             External.run(%{
               "api" => "api.example.com",
               "site" => "site.example.com",
               "s3" => "s3.example.com"
             })
  end

  test "the worker stores the health and alerts on changes" do
    Application.put_env(:bastion, :telegram_bot_token, "bot")
    Application.put_env(:bastion, :telegram_chat_id, "42")
    test_pid = self()

    stub(fn
      %{host: "api.telegram.org"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram, Jason.decode!(body)["text"]})
        Req.Test.json(conn, %{"ok" => true})

      %{host: "api.example.com"} = conn ->
        Plug.Conn.send_resp(conn, 502, "")

      conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
    end)

    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())

    assert :ok = perform_job()

    assert [%{health: "down", external: %{"api" => %{"status" => 502}}}] =
             Instances.list_instances()

    assert_received {:telegram,
                     "🔴 Pizza: сайт работает с ошибками\n• API не отвечает снаружи (HTTP 502)"}

    assert :ok = perform_job()
    refute_received {:telegram, _}

    stub(fn
      %{host: "api.telegram.org"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram, Jason.decode!(body)["text"]})
        Req.Test.json(conn, %{"ok" => true})

      conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
    end)

    assert :ok = perform_job()
    assert_received {:telegram, "✅ Pizza: всё работает\nПростой: " <> _}
    assert [%{ended_at: %DateTime{}}] = Bastion.Downtime.list_incidents(instance.id)
  end

  test "a planned stop and a running command do not raise alarms" do
    Application.put_env(:bastion, :telegram_bot_token, "bot")
    Application.put_env(:bastion, :telegram_chat_id, "42")
    test_pid = self()

    stub(fn
      %{host: "api.telegram.org"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram, Jason.decode!(body)["text"]})
        Req.Test.json(conn, %{"ok" => true})

      conn ->
        Plug.Conn.send_resp(conn, 502, "")
    end)

    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    {:ok, _} = Instances.update_checks(instance, %{}, :ok)

    command =
      Repo.insert!(%Bastion.Instances.Command{
        instance_id: instance.id,
        action: "stop",
        status: "running"
      })

    assert :ok = perform_job()
    assert [%{health: "ok"}] = Instances.list_instances()
    refute_received {:telegram, _}

    {:ok, _} = Instances.command_finished(instance.id, command.id, true, "stopped")
    assert [%{stopped_at: %DateTime{}}] = Instances.list_instances()

    assert :ok = perform_job()
    assert [%{health: "stopped"}] = Instances.list_instances()
    assert_received {:telegram, "⏸ Pizza: выключен по плану"}

    start =
      Repo.insert!(%Bastion.Instances.Command{
        instance_id: instance.id,
        action: "start",
        status: "running"
      })

    {:ok, _} = Instances.command_finished(instance.id, start.id, true, "started")
    assert [%{stopped_at: nil}] = Instances.list_instances()
  end

  defp perform_job, do: Worker.perform(%Oban.Job{})
end
