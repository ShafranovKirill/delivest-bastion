defmodule Bastion.Telegram.Bot do
  @moduledoc "Answers messages and buttons in the bot chat and reports command results."

  alias Bastion.{Instances, Telegram}
  alias Bastion.Telegram.Screens

  @notify_actions ~w(update start stop restart env_write)
  @commands [
    %{command: "menu", description: "Главное меню"},
    %{command: "sites", description: "Сети и их состояние"},
    %{command: "downtime", description: "Простой за сутки, неделю и месяц"}
  ]

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

  def command_finished(%{status: status} = command) when status in ["ok", "error"] do
    with true <- notify?(command),
         %{} = instance <- Instances.get_instance(command.instance_id) do
      Telegram.send_message(Screens.command_result(instance, command), %{
        parse_mode: "HTML",
        reply_markup: Telegram.keyboard([[{"Открыть", "i:" <> instance.id}]])
      })
    else
      _ -> :skipped
    end
  end

  def command_finished(_command), do: :skipped

  defp notify?(%{action: action}) when action in @notify_actions, do: true
  defp notify?(%{action: "logs", requested_by: "telegram:" <> _}), do: true
  defp notify?(_command), do: false

  defp screen(text) do
    case text |> String.split([" ", "@"]) |> hd() do
      "/sites" -> Screens.instances()
      "/downtime" -> Screens.downtime()
      _ -> Screens.menu()
    end
  end

  defp handle_callback(%{"data" => data} = query) do
    case String.split(data, ":", parts: 3) do
      ["m"] -> show(query, Screens.menu())
      ["l"] -> show(query, Screens.instances())
      ["d"] -> show(query, Screens.downtime())
      ["i", id] -> with_instance(query, id, &show(query, Screens.instance(&1)))
      ["di", id] -> with_instance(query, id, &show(query, Screens.incidents(&1)))
      ["a", action, id] -> with_instance(query, id, &ask(query, &1, action))
      ["y", action, id] -> with_instance(query, id, &run(query, &1, action))
      _ -> answer(query)
    end
  end

  defp handle_callback(query), do: answer(query)

  defp with_instance(query, id, fun) do
    case Instances.get_instance(id) do
      nil -> answer(query, "Сеть не найдена")
      instance -> fun.(instance)
    end
  end

  defp ask(query, instance, action) do
    if Screens.confirm?(action),
      do: show(query, Screens.confirm(instance, action)),
      else: run(query, instance, action)
  end

  defp run(query, instance, action) do
    args = if action == "logs", do: %{"tail" => "100"}, else: %{}

    notice =
      case Instances.send_command(instance, action, args, requester(query["from"])) do
        {:ok, _command} -> "#{Instances.action_label(action)}: отправлено"
        {:error, :offline} -> "Агент не на связи"
        {:error, :unknown_action} -> "Неизвестная команда"
      end

    answer(query, notice)
    edit(query, Screens.instance(Instances.get_instance(instance.id) || instance))
  end

  defp show(query, screen) do
    answer(query)
    edit(query, screen)
  end

  defp answer(query, text \\ nil) do
    params =
      if text,
        do: %{callback_query_id: query["id"], text: text},
        else: %{callback_query_id: query["id"]}

    Telegram.call("answerCallbackQuery", params)
  end

  defp edit(%{"message" => message}, {text, buttons}) do
    case Telegram.call("editMessageText", %{
           chat_id: message["chat"]["id"],
           message_id: message["message_id"],
           text: text,
           parse_mode: "HTML",
           reply_markup: Telegram.keyboard(buttons),
           link_preview_options: %{is_disabled: true}
         }) do
      {:error, "Bad Request: message is not modified" <> _} -> {:ok, :not_modified}
      result -> result
    end
  end

  defp send_screen({text, buttons}, chat_id) do
    Telegram.call("sendMessage", %{
      chat_id: chat_id,
      text: text,
      parse_mode: "HTML",
      reply_markup: Telegram.keyboard(buttons),
      link_preview_options: %{is_disabled: true}
    })
  end

  defp requester(%{"username" => username}) when is_binary(username),
    do: "telegram:@" <> username

  defp requester(%{"first_name" => name}) when is_binary(name), do: "telegram:" <> name
  defp requester(_from), do: "telegram"
end
