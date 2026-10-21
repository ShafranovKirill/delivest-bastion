defmodule Bastion.TelegramTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.Instances
  alias Bastion.Telegram.Bot
  alias BastionWeb.Presence

  @chat 42

  setup do
    Application.put_env(:bastion, :telegram_bot_token, "bot")
    Application.put_env(:bastion, :telegram_chat_id, to_string(@chat))
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:telegram, List.last(conn.path_info), Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true, "result" => %{}})
    end)

    on_exit(fn ->
      Application.delete_env(:bastion, :telegram_chat_id)
      Application.put_env(:bastion, :telegram_bot_token, nil)
    end)
  end

  defp message(text, chat \\ @chat),
    do: %{"update_id" => 1, "message" => %{"chat" => %{"id" => chat}, "text" => text}}

  defp press(data) do
    Bot.handle_update(%{
      "update_id" => 2,
      "callback_query" => %{
        "id" => "q1",
        "data" => data,
        "from" => %{"username" => "kirill"},
        "message" => %{"message_id" => 7, "chat" => %{"id" => @chat}}
      }
    })
  end

  defp buttons(%{"reply_markup" => %{"inline_keyboard" => rows}}),
    do: for(row <- rows, button <- row, do: {button["text"], button["callback_data"]})

  defp bring_online(instance) do
    test_pid = self()

    spawn_link(fn ->
      Instances.subscribe_commands(instance.id)
      {:ok, _} = Presence.track_agent(self(), instance.id)
      send(test_pid, :online)

      receive do
        {:push_command, command} -> send(test_pid, {:agent_got, command.action, command.args})
      end

      Process.sleep(:infinity)
    end)

    assert_receive :online
  end

  test "strangers only learn their chat id" do
    Bot.handle_update(message("/start", 1))
    assert_received {:telegram, "sendMessage", %{"chat_id" => 1, "text" => text} = body}
    assert text =~ "ID чата: 1"
    refute body["reply_markup"]
  end

  test "the menu leads to the list of sites" do
    instance = instance_fixture(%{info: %{"name" => "Pizza <North>"}})
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())

    Bot.handle_update(message("/start"))
    assert_received {:telegram, "sendMessage", %{"text" => text} = menu}
    assert text =~ "Сетей: 1"
    assert {"🏪 Сети", "l"} in buttons(menu)

    press("l")
    assert_received {:telegram, "answerCallbackQuery", %{"callback_query_id" => "q1"}}
    assert_received {:telegram, "editMessageText", %{"message_id" => 7, "text" => text} = list}
    assert text =~ "Pizza &lt;North&gt;"
    assert Enum.any?(buttons(list), &match?({_, "i:" <> _}, &1))
  end

  test "an online site can be restarted after a confirmation" do
    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    bring_online(instance)

    press("i:" <> instance.id)
    assert_received {:telegram, "editMessageText", %{"text" => text} = screen}
    assert text =~ "✅ server"
    assert text =~ "📈 24 ч: 100% · 7 дн: 100%"
    assert {"♻️ Перезапустить", "a:restart:" <> instance.id} in buttons(screen)

    press("a:restart:" <> instance.id)
    assert_received {:telegram, "editMessageText", %{"text" => "Перезапустить <b>Pizza</b>?"}}
    refute_received {:agent_got, _, _}

    press("y:restart:" <> instance.id)
    assert_receive {:agent_got, "restart", %{}}
    assert_received {:telegram, "answerCallbackQuery", %{"text" => "Перезапуск: отправлено"}}
    assert [%{requested_by: "telegram:@kirill"}] = Instances.list_commands(instance.id)
  end

  test "logs are requested without a confirmation and sent to the chat" do
    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    bring_online(instance)

    press("a:logs:" <> instance.id)
    assert_receive {:agent_got, "logs", %{"tail" => "100"}}

    [command] = Instances.list_commands(instance.id)
    {:ok, command} = Instances.command_finished(instance.id, command.id, true, "a < b")

    Bot.command_finished(command)

    assert_received {:telegram, "sendMessage",
                     %{"text" => "📜 <b>Pizza: Логи</b>\n<pre>a &lt; b</pre>"}}
  end

  test "finished site commands are reported, reads are not" do
    instance = instance_fixture(%{info: %{"name" => "Pizza"}})

    update =
      Repo.insert!(%Instances.Command{
        instance_id: instance.id,
        action: "update",
        status: "error",
        output: "pull denied",
        requested_by: "admin"
      })

    Bot.command_finished(update)
    assert_received {:telegram, "sendMessage", %{"text" => text}}
    assert text == "❌ <b>Pizza: Обновление</b> — ошибка (admin)\n<pre>pull denied</pre>"

    for action <- ["env_read", "status", "logs"] do
      assert :skipped =
               Bot.command_finished(%Instances.Command{
                 instance_id: instance.id,
                 action: action,
                 status: "ok",
                 requested_by: "admin"
               })
    end

    assert :skipped = Bot.command_finished(%{update | status: "running"})
  end

  test "the server polls updates and answers them" do
    Req.Test.set_req_test_to_shared()
    on_exit(&Req.Test.set_req_test_to_private/0)
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(body)
      send(test_pid, {:telegram, List.last(conn.path_info), body})

      result =
        case {List.last(conn.path_info), body["offset"]} do
          {"getUpdates", nil} -> [message("/start")]
          {"getUpdates", _offset} -> Process.sleep(1_000) && []
          _ -> %{}
        end

      Req.Test.json(conn, %{"ok" => true, "result" => result})
    end)

    start_supervised!(Bastion.Telegram.Server)

    assert_receive {:telegram, "setMyCommands", _}
    assert_receive {:telegram, "sendMessage", %{"chat_id" => @chat, "text" => text}}
    assert text =~ "Delivest Bastion"
    assert_receive {:telegram, "getUpdates", %{"offset" => 2}}
  end

  test "the downtime screen shows every site" do
    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    Bastion.Downtime.track(instance, %{level: :down, problems: ["API"]})

    press("d")
    assert_received {:telegram, "editMessageText", %{"text" => text}}
    assert text =~ "<b>Pizza</b>"
    assert text =~ "🔴 Сейчас простой"

    press("di:" <> instance.id)
    assert_received {:telegram, "editMessageText", %{"text" => text}}
    assert text =~ "(идёт)"
  end
end
