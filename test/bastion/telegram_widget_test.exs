defmodule Bastion.Telegram.WidgetTest do
  use Bastion.DataCase, async: false
  import Bastion.Fixtures

  alias Bastion.{Images, Instances}
  alias Bastion.Telegram.{Bot, Cards, Widget}

  setup do
    Application.put_env(:bastion, :telegram_bot_token, "bot")
    Application.put_env(:bastion, :telegram_chat_id, "42")
    parent = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:api, List.last(conn.path_info), Jason.decode!(body)})
      Req.Test.json(conn, %{ok: true, result: %{message_id: 71}})
    end)

    on_exit(fn ->
      Application.delete_env(:bastion, :telegram_chat_id)
      Application.put_env(:bastion, :telegram_bot_token, nil)
    end)

    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())

    start_supervised!(
      {Task,
       fn ->
         Instances.subscribe_commands(instance.id)
         {:ok, _} = BastionWeb.Presence.track_agent(self(), instance.id)
         send(parent, :online)

         forward = fn forward ->
           receive do
             {:push_command, command} ->
               send(parent, {:agent_command, command})
               forward.(forward)
           end
         end

         forward.(forward)
       end}
    )

    assert_receive :online
    %{instance: Instances.get_instance(instance.id)}
  end

  defp request(data, overrides \\ %{}) do
    %{
      "id" => "q",
      "chat" => %{"id" => 42, "type" => "private"},
      "from" => %{"id" => 42},
      "message_id" => 71,
      "data" => data,
      "type" => %{"type" => "data"}
    }
    |> Map.merge(overrides)
  end

  defp action(body, action) do
    %{"b" => buttons} = Jason.decode!(body["chat_data"])

    Enum.find_value(buttons, fn [_label, data] ->
      if String.ends_with?(data, ":" <> action), do: data
    end)
  end

  test "normal entry paths send private widgets with status and a unified version", %{
    instance: instance
  } do
    Bot.handle_update(%{"message" => %{"chat" => %{"id" => 42}, "text" => "Pizza"}})
    assert_received {:api, "sendWidget", body}
    assert body["allow_queries"]
    assert byte_size(body["chat_data"]) <= 1024
    assert byte_size(body["html"]) <= 32768
    data = Jason.decode!(body["chat_data"])
    assert data["n"] == "Pizza"
    {current, _} = Images.site_versions(instance)
    assert data["v"] == (current || "—")
    assert action(body, "restart")
    refute action(body, "rollback")
    refute action(body, "logs")

    for prefix <- ["i:", "o:"] do
      Bot.handle_update(%{
        "callback_query" => %{
          "id" => "c",
          "data" => prefix <> instance.id,
          "message" => %{"message_id" => 10, "chat" => %{"id" => 42}}
        }
      })

      assert_received {:api, "sendWidget", _}
    end

    refute_received {:api, "editMessageText", _}
  end

  test "queries require both the allowed private chat and actor, and a data query", %{
    instance: instance
  } do
    Widget.send(instance, 42)
    assert_received {:api, "sendWidget", body}
    data = action(body, "restart")

    for override <- [
          %{"from" => %{"id" => 99}},
          %{"chat" => %{"id" => 99, "type" => "private"}},
          %{"chat" => %{"id" => 42, "type" => "group"}},
          %{"type" => %{"type" => "sign_data"}}
        ] do
      assert :error = Widget.resolve(request(data, override))
    end

    assert {:ok, _, "restart", nil} = Widget.resolve(request(data))
    assert :error = Widget.resolve(request(data))
  end

  test "confirmation rotates tokens and cannot be forged or replayed", %{instance: instance} do
    Widget.send(instance, 42)
    assert_received {:api, "sendWidget", body}
    restart = action(body, "restart")
    [token, _] = String.split(restart, ":")
    assert :error = Widget.resolve(request(token <> ":confirm"))
    assert :error = Widget.resolve(request(token <> ":env_read"))
    Bot.handle_update(%{"widget_query" => request(restart)})
    assert_received {:api, "answerWidgetQuery", _}
    assert_received {:api, "editMessageWidgetData", confirmation}
    assert action(confirmation, "confirm")
    assert :error = Widget.resolve(request(restart))

    assert {:ok, _, "confirm", "restart"} =
             Widget.resolve(request(action(confirmation, "confirm")))

    assert :error = Widget.resolve(request(action(confirmation, "confirm")))
    assert Instances.list_commands(instance.id) == []
  end

  test "expired and currently unavailable actions are rejected", %{instance: instance} do
    Widget.send(instance, 42)
    assert_received {:api, "sendWidget", body}
    session = Cards.session(42, 71)
    Cards.session(42, 71, %{session | expires: System.monotonic_time(:second) - 1})
    assert :error = Widget.resolve(request(action(body, "restart")))
    Widget.send(instance, 42)
    assert_received {:api, "sendWidget", body}
    {:ok, _command} = Instances.send_command(instance, "restart")
    assert :error = Widget.resolve(request(action(body, "restart")))
  end

  test "a confirmed restart dispatches once and stays in its widget", %{instance: instance} do
    Widget.send(instance, 42)
    assert_received {:api, "sendWidget", body}
    Bot.handle_update(%{"widget_query" => request(action(body, "restart"))})
    assert_received {:api, "editMessageWidgetData", confirmation}
    data = action(confirmation, "confirm")
    Bot.handle_update(%{"widget_query" => request(data)})
    assert_receive {:agent_command, command}
    assert command.action == "restart"
    assert_received {:api, "editMessageWidgetData", progress}
    assert Jason.decode!(progress["chat_data"])["m"] =~ "Перезапуск"
    assert Cards.get(command.id) == {:widget, 42, 71}
    Bot.handle_update(%{"widget_query" => request(data)})
    refute_receive {:agent_command, _}
    assert length(Instances.list_commands(instance.id)) == 1
    refute_received {:api, "editMessageText", _}
  end

  test "progress and completion edit widget state, never media as text", %{instance: instance} do
    Widget.send(instance, 42)
    assert_received {:api, "sendWidget", _}

    command = %Instances.Command{
      id: Ecto.UUID.generate(),
      instance_id: instance.id,
      action: "restart",
      status: "running",
      requested_by: "telegram"
    }

    Cards.put_widget(command.id, 42, 71)
    Bot.command_updated(command)
    assert_received {:api, "editMessageWidgetData", _}
    Bot.command_updated(%{command | status: "ok"})
    assert_received {:api, "editMessageWidgetData", body}
    assert Jason.decode!(body["chat_data"])["m"] =~ "готово"
    assert Cards.get(command.id) == nil
    refute_received {:api, "editMessageText", _}
  end

  test "unsupported API falls back to an ordinary card", %{instance: _instance} do
    parent = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      method = List.last(conn.path_info)
      send(parent, {:api, method, Jason.decode!(body)})

      if method == "sendWidget",
        do: Req.Test.json(conn, %{ok: false, description: "Not Found"}),
        else: Req.Test.json(conn, %{ok: true, result: %{message_id: 71}})
    end)

    Bot.handle_update(%{"message" => %{"chat" => %{"id" => 42}, "text" => "Pizza"}})
    assert_received {:api, "sendWidget", _}
    assert_received {:api, "sendMessage", %{"text" => text, "reply_markup" => _}}
    assert text =~ "Pizza"
    Application.put_env(:bastion, :telegram_chat_id, "-42")
    assert {:error, :unsupported_chat} = Widget.send(%{}, -42)
  end

  test "oversized UTF-8 and escaped fields fit the API state limit", %{instance: instance} do
    instance = %{instance | name: String.duplicate("😀\"", 1000)}
    Widget.send(instance, 42)
    assert_received {:api, "sendWidget", body}
    assert byte_size(body["chat_data"]) <= 1024
    assert Jason.decode!(body["chat_data"])["n"] != ""
  end

  test "unsupported clients can open ordinary buttons without editing widget media", %{
    instance: instance
  } do
    Widget.send(instance, 42)
    assert_received {:api, "sendWidget", _}

    Bot.handle_update(%{
      "callback_query" => %{
        "id" => "c",
        "data" => "f:" <> instance.id,
        "message" => %{"message_id" => 71, "chat" => %{"id" => 42}, "widget" => %{}}
      }
    })

    assert_received {:api, "sendMessage", %{"reply_markup" => %{"inline_keyboard" => rows}}}
    assert Enum.any?(List.flatten(rows), &(&1["callback_data"] == "a:restart:" <> instance.id))
    refute_received {:api, "editMessageText", _}
  end

  test "widget HTML stays below the compressed API limit" do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 9)
    compressed = :zlib.deflate(z, Widget.html(), :finish) |> IO.iodata_to_binary()
    :zlib.close(z)
    assert byte_size(compressed) <= 4096
    refute Widget.html() =~ "innerHTML"
    refute Widget.html() =~ "fetch("
  end
end
