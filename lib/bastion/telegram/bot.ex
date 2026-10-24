defmodule Bastion.Telegram.Bot do
  @moduledoc """
  Answers messages and buttons in the bot chat. A command sent from a site card updates
  that card while it runs; other finished commands are reported with a new message.
  """

  alias Bastion.{Alerts, Backups, CrmAlerts, Instances, Telegram, Updates}
  alias Bastion.Telegram.{Cards, Screens}

  require Logger

  @notify_actions ~w(update rollback agent_update start stop restart env_write restore)
  @commands [%{command: "sites", description: "Все сети"}]

  def setup do
    Telegram.call("deleteWebhook", %{})
    Telegram.call("setMyCommands", %{commands: @commands})
  end

  def handle_update(%{"callback_query" => %{"message" => %{"chat" => chat}} = query}) do
    if Telegram.allowed_chat?(chat["id"]),
      do: handle_callback(query),
      else: answer(query, "Нет доступа")
  end

  def handle_update(%{"message" => %{"chat" => %{"id" => chat_id}, "text" => text}}) do
    if Telegram.allowed_chat?(chat_id) do
      text |> screen() |> send_screen(chat_id)
    else
      Telegram.call("sendMessage", %{
        chat_id: chat_id,
        text: "Этот чат не подключён к бастиону. ID чата: #{chat_id}"
      })
    end
  end

  def handle_update(_update), do: :ignored

  def command_updated(command) do
    case Cards.get(command.id) do
      nil -> command_finished(command)
      card -> update_card(card, command)
    end
  end

  def command_finished(%{status: status} = command) when status in ["ok", "error"] do
    with true <- notify?(command),
         %{} = instance <- Instances.get_instance(command.instance_id) do
      if command.action == "logs" and status == "ok",
        do: send_logs(instance, command, %{}),
        else:
          Telegram.send_message(Screens.command_result(instance, command), %{
            parse_mode: "HTML",
            reply_markup: Telegram.keyboard([[Alerts.open_button(instance)]])
          })
    else
      _ -> :skipped
    end
  end

  def command_finished(_command), do: :skipped

  defp notify?(%{action: action}) when action in @notify_actions, do: true
  defp notify?(%{action: "logs", requested_by: "telegram" <> _}), do: true
  defp notify?(_command), do: false

  defp update_card({chat_id, message_id} = card, command) do
    with %{} = instance <- Instances.get_instance(command.instance_id) do
      if command.status in ["ok", "error"] do
        Cards.delete(command.id)
        edit(card, Screens.instance(instance, Screens.notice(command)))
        reply = %{chat_id: chat_id, reply_parameters: %{message_id: message_id}}

        cond do
          command.status == "error" and command.output not in [nil, ""] ->
            Telegram.call(
              "sendMessage",
              Map.merge(reply, %{
                text: Screens.error_output(command),
                parse_mode: "HTML"
              })
            )

          command.action == "logs" and command.status == "ok" ->
            send_logs(instance, command, reply)

          true ->
            :ok
        end
      else
        edit(card, Screens.instance(instance))
      end
    end
  end

  defp send_logs(instance, command, params) do
    Telegram.send_document(
      Screens.logs_file(instance),
      command.output || "",
      Map.put(params, :caption, "📜 #{instance.name}: логи")
    )
  end

  # Any text that is not a command looks for a site by its name or host.
  defp screen("/" <> _command), do: Screens.instances()

  defp screen(text) do
    query = text |> String.trim() |> String.downcase()

    matches =
      Enum.filter(Instances.list_instances(), fn instance ->
        [instance.name | Map.values(instance.hosts)]
        |> Enum.any?(&String.contains?(String.downcase(to_string(&1)), query))
      end)

    case matches do
      [instance] -> Screens.instance(instance)
      [] -> Screens.not_found(String.trim(text))
      matches -> Screens.instances(matches, "Найдено")
    end
  end

  defp handle_callback(%{"data" => data} = query) do
    case String.split(data, ":", parts: 3) do
      [list] when list in ["l", "m", "d"] ->
        show(query, Screens.instances())

      ["i", id] ->
        with_instance(query, id, &show(query, Screens.instance(&1)))

      ["o", id] ->
        with_instance(query, id, &open(query, &1))

      [details, id] when details in ["x", "di"] ->
        with_instance(query, id, &show(query, Screens.details(&1)))

      ["e", id] ->
        with_instance(query, id, &show(query, Screens.more(&1)))

      ["cm", id] ->
        with_instance(query, id, &toggle_mute(query, &1))

      ["mute", id] ->
        with_instance(query, id, &mute_from_alert(query, &1))

      ["logs", id] ->
        with_instance(query, id, &logs_from_alert(query, &1))

      ["cx", id, order_id] ->
        with_instance(query, id, &dismiss_order(query, &1, order_id))

      ["a", action, id] ->
        with_instance(query, id, &ask(query, &1, action))

      ["y", action, id] ->
        with_instance(query, id, &run(query, &1, action))

      _ ->
        answer(query)
    end
  end

  defp handle_callback(query), do: answer(query)

  defp with_instance(query, id, fun) do
    case Instances.get_instance(id) do
      nil -> answer(query, "Сеть не найдена")
      instance -> fun.(instance)
    end
  end

  # A card opened from an alert is a new message, so the alert stays in the chat.
  defp open(%{"message" => message} = query, instance) do
    answer(query)

    send_screen(Screens.instance(instance), message["chat"]["id"], %{
      reply_parameters: %{message_id: message["message_id"], allow_sending_without_reply: true}
    })
  end

  defp toggle_mute(query, instance) do
    {:ok, instance} =
      if Alerts.muted?(instance), do: Alerts.unmute(instance), else: Alerts.mute(instance)

    answer(
      query,
      if(Alerts.muted?(instance),
        do: "Уведомления выключены на час",
        else: "Уведомления включены"
      )
    )

    edit(query, Screens.instance(instance))
  end

  defp mute_from_alert(query, instance) do
    {:ok, _instance} = Alerts.mute(instance)
    answer(query, "#{instance.name}: тихо на час")
    edit_buttons(query, [[Alerts.open_button(instance)]])
  end

  defp logs_from_alert(query, instance) do
    case Instances.send_command(instance, "logs", %{"tail" => "300"}, requester(query["from"])) do
      {:ok, _command} -> answer(query, "Логи придут файлом")
      {:error, :offline} -> answer(query, "Агент не на связи")
    end
  end

  defp dismiss_order(query, instance, order_id) do
    {:ok, _instance} = CrmAlerts.dismiss(instance, order_id)
    answer(query, "Заказ скрыт")
    edit_buttons(query, [[Alerts.open_button(instance)]])
  end

  defp ask(query, instance, action) do
    if Screens.confirm?(action),
      do: show(query, Screens.confirm(instance, action)),
      else: run(query, instance, action)
  end

  defp run(%{"message" => message} = query, instance, action) do
    requested_by = requester(query["from"])

    sent =
      case action do
        "update" -> Updates.update(instance, requested_by)
        "backup" -> backup(instance, requested_by)
        "logs" -> Instances.send_command(instance, "logs", %{"tail" => "300"}, requested_by)
        _ -> Instances.send_command(instance, action, %{}, requested_by)
      end

    case sent do
      {:ok, command} ->
        Cards.put(command.id, message["chat"]["id"], message["message_id"])
        answer(query)

      {:error, :offline} ->
        answer(query, "Агент не на связи")

      {:error, :unknown_action} ->
        answer(query, "Агент не умеет: #{Instances.action_label(action)}")

      {:error, reason} when is_binary(reason) ->
        answer(query, "Не получилось: #{reason}")
    end

    edit(query, Screens.instance(Instances.get_instance(instance.id) || instance))
  end

  defp backup(instance, requested_by) do
    with {:ok, backup} <- Backups.start(instance, requested_by) do
      {:ok, %{id: backup.command_id}}
    end
  end

  defp show(query, screen) do
    case edit(query, screen) do
      {:error, reason} -> answer(query, "Telegram: #{reason}")
      _ -> answer(query)
    end
  end

  defp answer(query, text \\ nil) do
    params =
      if text,
        do: %{callback_query_id: query["id"], text: String.slice(text, 0, 200)},
        else: %{callback_query_id: query["id"]}

    Telegram.call("answerCallbackQuery", params)
  end

  defp edit(%{"message" => message}, screen),
    do: edit({message["chat"]["id"], message["message_id"]}, screen)

  defp edit({chat_id, message_id}, {text, buttons}) do
    case Telegram.call("editMessageText", %{
           chat_id: chat_id,
           message_id: message_id,
           text: text,
           parse_mode: "HTML",
           reply_markup: Telegram.keyboard(buttons),
           link_preview_options: %{is_disabled: true}
         }) do
      {:error, "Bad Request: message is not modified" <> _} -> {:ok, :not_modified}
      {:error, reason} -> log_failure("editMessageText", reason, text)
      result -> result
    end
  end

  defp log_failure(method, reason, text) do
    Logger.warning(
      "telegram #{method} failed: #{inspect(reason)} for #{inspect(String.slice(text, 0, 80))}"
    )

    {:error, reason}
  end

  defp edit_buttons(%{"message" => message}, buttons) do
    Telegram.call("editMessageReplyMarkup", %{
      chat_id: message["chat"]["id"],
      message_id: message["message_id"],
      reply_markup: Telegram.keyboard(buttons)
    })
  end

  defp send_screen({text, buttons}, chat_id, params \\ %{}) do
    case Telegram.call(
           "sendMessage",
           Map.merge(params, %{
             chat_id: chat_id,
             text: text,
             parse_mode: "HTML",
             reply_markup: Telegram.keyboard(buttons),
             link_preview_options: %{is_disabled: true}
           })
         ) do
      {:error, reason} -> log_failure("sendMessage", reason, text)
      result -> result
    end
  end

  defp requester(%{"username" => username}) when is_binary(username),
    do: "telegram:@" <> username

  defp requester(%{"first_name" => name}) when is_binary(name), do: "telegram:" <> name
  defp requester(_from), do: "telegram"
end
