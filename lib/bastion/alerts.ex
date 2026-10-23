defmodule Bastion.Alerts do
  require Logger

  alias Bastion.{Downtime, Telegram}
  alias Bastion.Instances.Instance

  @silent ["unknown"]

  def health_changed(
        %Instance{} = instance,
        previous,
        %{level: level} = health,
        downtime \\ :none
      ) do
    if previous in @silent and level == :ok,
      do: :skipped,
      else: instance |> message(health, downtime) |> send_message(open_button(instance))
  end

  defp open_button(instance),
    do: %{reply_markup: Telegram.keyboard([[{"Открыть", "i:" <> instance.id}]])}

  def message(instance, health, downtime \\ :none)

  def message(%Instance{} = instance, health, {:closed, incident}) do
    message(instance, health) <>
      "\nПростой: #{Downtime.format_duration(Downtime.duration(incident))}"
  end

  def message(%Instance{name: name}, %{level: level, problems: problems}, _downtime) do
    title =
      case level do
        :ok -> "✅ #{name}: всё работает"
        :warning -> "⚠️ #{name}: есть предупреждения"
        :down -> "🔴 #{name}: сайт работает с ошибками"
        :offline -> "⚫ #{name}: агент не на связи"
        :stopped -> "⏸ #{name}: выключен по плану"
        :unknown -> "❔ #{name}: нет данных"
      end

    Enum.join([title | Enum.map(problems, &("• " <> &1))], "\n")
  end

  def notify(%Instance{} = instance, text), do: send_message(text, open_button(instance))

  def send_message(text, params \\ %{}) do
    Bastion.Push.notify(text, push_url(params))

    if Telegram.configured?() do
      case Telegram.send_message(text, params) do
        {:ok, _message} ->
          :ok

        {:error, reason} ->
          Logger.warning("telegram alert was not sent: #{inspect(reason)}")
          :error
      end
    else
      :skipped
    end
  end

  # The "Открыть" button of an alert leads to the instance page in a push too.
  defp push_url(%{reply_markup: %{inline_keyboard: rows}}) do
    Enum.find_value(List.flatten(rows), "/", fn
      %{callback_data: "i:" <> id} -> "/instances/" <> id
      _ -> nil
    end)
  end

  defp push_url(_params), do: "/"
end
