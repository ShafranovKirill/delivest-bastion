defmodule Bastion.Alerts do
  require Logger

  alias Bastion.Instances.Instance

  @silent ["unknown"]

  def health_changed(%Instance{} = instance, previous, %{level: level} = health) do
    if previous in @silent and level == :ok,
      do: :skipped,
      else: instance |> message(health) |> send_message()
  end

  def message(%Instance{name: name}, %{level: level, problems: problems}) do
    title =
      case level do
        :ok -> "✅ #{name}: всё работает"
        :warning -> "⚠️ #{name}: есть предупреждения"
        :down -> "🔴 #{name}: сайт работает с ошибками"
        :offline -> "⚫ #{name}: агент не на связи"
        :unknown -> "❔ #{name}: нет данных"
      end

    Enum.join([title | Enum.map(problems, &("• " <> &1))], "\n")
  end

  def send_message(text) do
    token = Application.get_env(:bastion, :telegram_bot_token)
    chat_id = Application.get_env(:bastion, :telegram_chat_id)

    if token && chat_id do
      case Req.post(
             "https://api.telegram.org/bot#{token}/sendMessage",
             [json: %{chat_id: chat_id, text: text}, retry: false] ++
               Application.get_env(:bastion, :req_options, [])
           ) do
        {:ok, %{status: 200}} ->
          :ok

        other ->
          Logger.warning("telegram alert was not sent: #{inspect(other)}")
          :error
      end
    else
      :skipped
    end
  end
end
