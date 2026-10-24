defmodule Bastion.TelegramTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.{Alerts, Instances}
  alias Bastion.Telegram.Bot
  alias BastionWeb.Presence

  @chat 42

  setup do
    Application.put_env(:bastion, :telegram_bot_token, "bot")
    Application.put_env(:bastion, :telegram_chat_id, to_string(@chat))
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        case Plug.Conn.get_req_header(conn, "content-type") do
          ["application/json" <> _] -> Jason.decode!(body)
          _ -> {:multipart, body}
        end

      send(test_pid, {:telegram, List.last(conn.path_info), body})
      Req.Test.json(conn, %{"ok" => true, "result" => %{"message_id" => 100}})
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
    do:
      for(
        row <- rows,
        button <- row,
        do: {button["text"], button["callback_data"] || button["url"]}
      )

  defp healthy(attrs) do
    instance = instance_fixture(%{info: attrs})
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    Instances.get_instance(instance.id)
  end

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

  test "the start lists sites with problems first and folds the working ones" do
    healthy(%{"name" => "Alpha"})
    broken = instance_fixture(%{info: %{"name" => "Pizza <North>"}})
    {:ok, _} = Instances.record_heartbeat(broken.id, %{healthy_status() | "checks" => %{}})

    broken
    |> Ecto.Changeset.change(last_seen_at: ~U[2020-01-01 00:00:00Z])
    |> Repo.update!()

    healthy(%{"name" => "Beta"})

    Bot.handle_update(message("/start"))
    assert_received {:telegram, "sendMessage", %{"text" => text} = list}
    assert text =~ "⚫ <b>Pizza &lt;North&gt;</b> — агент не на связи"
    assert text =~ "🟢 Остальные работают: 2"
    assert [{"⚫ Pizza <North>", "i:" <> _}, {"🟢 Alpha", _}, {"🟢 Beta", _} | _] = buttons(list)
  end

  test "a text finds the site and its card links the site and the admin" do
    healthy(%{"name" => "Pizza"})
    healthy(%{"name" => "Sushi"})

    Bot.handle_update(message("piz"))
    assert_received {:telegram, "sendMessage", %{"text" => text} = card}
    assert text =~ "🟢 <b>Pizza</b> — работает"
    assert text =~ "диск 40% · бэкапов нет · аптайм 30 дн 100%"
    assert {"🌐 Сайт", "https://site.example.com"} in buttons(card)
    assert {"🛠 Админка", "https://api.example.com/staff/dashboard"} in buttons(card)

    Bot.handle_update(message("nothing"))
    assert_received {:telegram, "sendMessage", %{"text" => "Не нашёл «nothing»." <> _}}
  end

  test "the card leaves out links to hosts telegram would reject" do
    instance =
      healthy(%{
        "name" => "Pizza",
        "hosts" => %{"api" => "https://api.example.com", "site" => "localhost"}
      })

    press("i:" <> instance.id)
    assert_received {:telegram, "editMessageText", card}
    refute Enum.any?(buttons(card), fn {text, _} -> text in ["🌐 Сайт", "🛠 Админка"] end)
  end

  test "a screen telegram rejects tells why instead of doing nothing" do
    instance = healthy(%{"name" => "Pizza"})
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:telegram, List.last(conn.path_info), Jason.decode!(body)})

      case List.last(conn.path_info) do
        "editMessageText" ->
          conn
          |> Plug.Conn.put_status(400)
          |> Req.Test.json(%{"ok" => false, "description" => "Bad Request: BUTTON_URL_INVALID"})

        _ ->
          Req.Test.json(conn, %{"ok" => true, "result" => true})
      end
    end)

    press("i:" <> instance.id)

    assert_received {:telegram, "answerCallbackQuery",
                     %{"text" => "Telegram: Bad Request: BUTTON_URL_INVALID"}}
  end

  test "a restart from the card shows its progress and result in the card" do
    instance = healthy(%{"name" => "Pizza"})
    bring_online(instance)

    press("e:" <> instance.id)
    assert_received {:telegram, "editMessageText", more}
    assert {"♻️ Перезапустить", "a:restart:" <> instance.id} in buttons(more)

    press("a:restart:" <> instance.id)
    assert_received {:telegram, "editMessageText", %{"text" => "Перезапустить <b>Pizza</b>?"}}
    refute_received {:agent_got, _, _}

    press("y:restart:" <> instance.id)
    assert_receive {:agent_got, "restart", %{}}
    assert_received {:telegram, "editMessageText", %{"message_id" => 7, "text" => text}}
    assert text =~ "⏳ Перезапуск…"

    [command] = Instances.list_commands(instance.id)
    assert command.requested_by == "telegram:@kirill"
    {:ok, command} = Instances.command_finished(instance.id, command.id, true, "")

    Bot.command_updated(command)
    assert_received {:telegram, "editMessageText", %{"message_id" => 7, "text" => text}}
    assert text =~ "✅ Перезапуск — готово"
    refute text =~ "⏳"
    refute_received {:telegram, "sendMessage", _}
  end

  test "logs from the card come as a file in reply to it" do
    instance = healthy(%{"name" => "Pizza"})
    bring_online(instance)

    press("a:logs:" <> instance.id)
    assert_receive {:agent_got, "logs", %{"tail" => "300"}}

    [command] = Instances.list_commands(instance.id)
    {:ok, command} = Instances.command_finished(instance.id, command.id, true, "a < b")

    Bot.command_updated(command)
    assert_received {:telegram, "sendDocument", {:multipart, body}}
    assert body =~ "a < b"
    assert body =~ ~s(filename="pizza-logs-)
    assert body =~ ~s("message_id":7)
  end

  test "commands from the web are reported, the requester only in a group" do
    instance = instance_fixture(%{info: %{"name" => "Pizza"}})

    update =
      Repo.insert!(%Instances.Command{
        instance_id: instance.id,
        action: "update",
        status: "error",
        output: "pull denied",
        requested_by: "admin"
      })

    Bot.command_updated(update)
    assert_received {:telegram, "sendMessage", %{"text" => text} = sent}
    assert text == "❌ <b>Pizza: Обновление</b> — ошибка\n<pre>pull denied</pre>"
    assert [{"Открыть", "o:" <> _}] = buttons(sent)

    Application.put_env(:bastion, :telegram_chat_id, "-100")
    Bot.command_updated(update)
    assert_received {:telegram, "sendMessage", %{"text" => text}}
    assert text =~ "ошибка (admin)"

    for action <- ["env_read", "status", "logs"] do
      assert :skipped =
               Bot.command_updated(%Instances.Command{
                 id: Ecto.UUID.generate(),
                 instance_id: instance.id,
                 action: action,
                 status: "ok",
                 requested_by: "admin"
               })
    end

    assert :skipped = Bot.command_updated(%{update | status: "running"})
  end

  test "an alert opens the card in a new message and keeps its own text" do
    instance = healthy(%{"name" => "Pizza"})

    press("o:" <> instance.id)
    refute_received {:telegram, "editMessageText", _}
    assert_received {:telegram, "sendMessage", %{"text" => text, "reply_parameters" => reply}}
    assert text =~ "<b>Pizza</b>"
    assert reply["message_id"] == 7
  end

  test "a recovery answers the alert and marks it as resolved" do
    instance = healthy(%{"name" => "Pizza"})

    Alerts.health_changed(instance, "ok", %{level: :down, problems: ["API"]})
    assert_received {:telegram, "sendMessage", %{"text" => "🔴 Pizza" <> _} = alert}
    assert {"🔕 Тихо 1 ч", "mute:" <> instance.id} in buttons(alert)

    Alerts.health_changed(instance, "down", %{level: :ok, problems: []})
    assert_received {:telegram, "sendMessage", %{"text" => "✅ Pizza" <> _} = recovery}
    assert recovery["reply_parameters"]["message_id"] == 100
    assert_received {:telegram, "editMessageText", %{"message_id" => 100, "text" => text}}
    assert text =~ "• API\n\n✅ Решено через"
  end

  test "a muted site stays silent for an hour" do
    instance = healthy(%{"name" => "Pizza"})

    press("mute:" <> instance.id)
    assert_received {:telegram, "answerCallbackQuery", %{"text" => "Pizza: тихо на час"}}
    assert_received {:telegram, "editMessageReplyMarkup", _}

    instance = Instances.get_instance(instance.id)
    assert :muted = Alerts.notify(instance, "🔥 Pizza: процессор", open: "cpu")
    refute_received {:telegram, "sendMessage", _}

    press("i:" <> instance.id)
    assert_received {:telegram, "editMessageText", %{"text" => text}}
    assert text =~ "🔕 Без уведомлений до"

    press("e:" <> instance.id)
    assert_received {:telegram, "editMessageText", more}
    assert {"🔔 Включить уведомления", "cm:" <> instance.id} in buttons(more)
  end

  test "a failed CRM order can be hidden from its alert" do
    instance = healthy(%{"name" => "Pizza"})

    Bastion.CrmAlerts.check(instance.id, [
      %{"id" => 5, "number" => "17", "status" => "failed", "attempts" => 3}
    ])

    assert_received {:telegram, "sendMessage", alert}
    assert {"🙈 Скрыть заказ", "cx:#{instance.id}:5"} in buttons(alert)

    press("cx:#{instance.id}:5")
    assert_received {:telegram, "answerCallbackQuery", %{"text" => "Заказ скрыт"}}
    assert Instances.get_instance(instance.id).crm_dismissed == ["5"]
  end

  test "the details show containers, uptime and incidents" do
    instance = healthy(%{"name" => "Pizza"})
    Bastion.Downtime.track(instance, %{level: :down, problems: ["API"]})

    press("x:" <> instance.id)
    assert_received {:telegram, "editMessageText", %{"text" => text}}
    assert text =~ "✅ server"
    assert text =~ ~s(site: <a href="https://site.example.com">)
    assert text =~ "<b>Аптайм</b>"
    assert text =~ "(идёт)"
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

    assert_receive {:telegram, "setMyCommands", %{"commands" => [%{"command" => "sites"}]}}
    assert_receive {:telegram, "sendMessage", %{"chat_id" => @chat, "text" => text}}
    assert text =~ "Пока ни один агент"
    assert_receive {:telegram, "getUpdates", %{"offset" => 2}}
  end
end
