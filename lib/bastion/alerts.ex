defmodule Bastion.Alerts do
  @moduledoc """
  Sends alerts to Telegram and push. An alert opened with a key is remembered, so the
  message about its end answers it and marks it as resolved. A muted site sends nothing.
  """

  require Logger

  import Ecto.Query, warn: false

  alias Bastion.{Downtime, Repo, Telegram}
  alias Bastion.Alerts.Thread
  alias Bastion.Instances.Instance

  @silent ["unknown"]
  @resolved [:ok, :stopped]
  @mute_seconds 3600

  def mute_seconds, do: @mute_seconds

  def health_changed(
        %Instance{} = instance,
        previous,
        %{level: level} = health,
        downtime \\ :none
      ) do
    cond do
      previous in @silent and level == :ok ->
        :skipped

      level in @resolved ->
        notify(instance, message(instance, health, downtime), resolve: "health")

      true ->
        notify(instance, message(instance, health, downtime), open: "health")
    end
  end

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

  @doc """
  An alert about the site. `open: key` starts an alert that is over with a later
  `resolve: key`; `buttons:` adds rows of buttons under the message.
  """
  def notify(%Instance{} = instance, text, opts \\ []) do
    if muted?(instance) do
      if key = opts[:resolve], do: close_thread(instance.id, key)
      :muted
    else
      Bastion.Push.notify(text, "/instances/" <> instance.id)
      deliver(instance, text, opts)
    end
  end

  def muted?(%Instance{muted_until: nil}), do: false

  def muted?(%Instance{muted_until: until}),
    do: DateTime.compare(until, DateTime.utc_now()) == :gt

  def mute(%Instance{} = instance, seconds \\ @mute_seconds) do
    until = DateTime.add(DateTime.utc_now(:second), seconds)
    set_muted(instance, until)
  end

  def unmute(%Instance{} = instance), do: set_muted(instance, nil)

  defp set_muted(instance, until) do
    with {:ok, updated} <-
           instance |> Ecto.Changeset.change(muted_until: until) |> Repo.update() do
      {:ok, %{updated | online: instance.online}}
    end
  end

  @doc "A message that is not about one site."
  def send_message(text, params \\ %{}) do
    Bastion.Push.notify(text, push_url(params))
    telegram(text, params)
  end

  defp telegram(text, params) do
    if Telegram.configured?() do
      case Telegram.send_message(text, params) do
        {:ok, message} ->
          {:ok, message}

        {:error, reason} ->
          Logger.warning("telegram alert was not sent: #{inspect(reason)}")
          :error
      end
    else
      :skipped
    end
  end

  def open_button(%Instance{id: id}), do: {"Открыть", "o:" <> id}

  defp deliver(instance, text, opts) do
    key = opts[:open] || opts[:resolve]
    thread = key && get_thread(instance.id, key)

    buttons =
      if opts[:resolve],
        do: [[open_button(instance)]],
        else: [[open_button(instance), {"🔕 Тихо 1 ч", "mute:" <> instance.id}]]

    params =
      %{reply_markup: Telegram.keyboard(buttons ++ Keyword.get(opts, :buttons, []))}
      |> reply_to(thread)

    case telegram(text, params) do
      {:ok, %{"message_id" => message_id}} ->
        if opts[:open], do: put_thread(instance.id, key, message_id, text)
        if opts[:resolve], do: close_thread(instance.id, key)
        :ok

      {:ok, _message} ->
        :ok

      other ->
        other
    end
  end

  defp reply_to(params, %Thread{message_id: message_id}),
    do:
      Map.put(params, :reply_parameters, %{
        message_id: message_id,
        allow_sending_without_reply: true
      })

  defp reply_to(params, nil), do: params

  defp get_thread(instance_id, key), do: Repo.get_by(Thread, instance_id: instance_id, key: key)

  defp put_thread(instance_id, key, message_id, text) do
    Repo.insert(
      %Thread{instance_id: instance_id, key: key, message_id: message_id, text: text},
      on_conflict: {:replace, [:message_id, :text, :inserted_at, :updated_at]},
      conflict_target: [:instance_id, :key]
    )
  end

  # The opened alert is marked as resolved in place, which does not notify anyone.
  defp close_thread(instance_id, key) do
    with %Thread{} = thread <- get_thread(instance_id, key) do
      Repo.delete(thread)
      took = Downtime.format_duration(DateTime.diff(DateTime.utc_now(), thread.inserted_at))

      if Telegram.configured?() do
        Telegram.call("editMessageText", %{
          chat_id: Telegram.chat_id(),
          message_id: thread.message_id,
          text: "#{thread.text}\n\n✅ Решено через #{took}",
          reply_markup: Telegram.keyboard([[open_button(%Instance{id: instance_id})]])
        })
      end
    end
  end

  # The "Открыть" button of an alert leads to the instance page in a push too.
  defp push_url(%{reply_markup: %{inline_keyboard: rows}}) do
    Enum.find_value(List.flatten(rows), "/", fn
      %{callback_data: "o:" <> id} -> "/instances/" <> id
      %{callback_data: "i:" <> id} -> "/instances/" <> id
      _ -> nil
    end)
  end

  defp push_url(_params), do: "/"
end
