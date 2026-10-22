defmodule Bastion.CrmAlerts do
  alias Bastion.{Alerts, Repo, Telegram}
  alias Bastion.Instances.Instance

  @recovery_window_seconds 23 * 3600

  def problems(%Instance{status: %{"crm" => orders}}) when is_list(orders), do: orders
  def problems(_instance), do: []

  def check(instance_id, orders, now \\ DateTime.utc_now(:second))

  def check(instance_id, orders, now) when is_list(orders) do
    with %Instance{} = instance <- Repo.get(Instance, instance_id) do
      current = Map.new(orders, &{to_string(&1["id"]), &1})

      for {id, order} <- current,
          Map.get(instance.crm_alerts, id, %{})["status"] != order["status"],
          do: notify(instance, message(instance, order))

      for {id, alerted} <- instance.crm_alerts,
          not Map.has_key?(current, id),
          alerted["status"] == "pending",
          recent?(alerted, now),
          do:
            notify(
              instance,
              "✅ #{instance.name}: заказ №#{alerted["number"]} больше не ждёт отправки в #{provider(alerted)}"
            )

      alerts =
        Map.new(current, fn {id, order} ->
          {id, Map.take(order, ["status", "number", "provider", "inserted_at"])}
        end)

      if alerts != instance.crm_alerts,
        do: instance |> Ecto.Changeset.change(crm_alerts: alerts) |> Repo.update(),
        else: :ok
    end
  end

  def check(_instance_id, _orders, _now), do: :skipped

  def provider(%{"provider" => "frontpad"}), do: "Frontpad"
  def provider(%{"provider" => provider}) when is_binary(provider), do: provider
  def provider(_order), do: "CRM"

  defp message(instance, %{"status" => "failed"} = order) do
    lines([
      "🚨 #{instance.name}: заказ №#{order["number"]} не ушёл в #{provider(order)}",
      order["branch"] && "Филиал: #{order["branch"]}",
      order["error"] && "Ошибка: #{order["error"]}",
      "Попыток: #{order["attempts"]}",
      "Передайте заказ вручную."
    ])
  end

  defp message(instance, order) do
    lines([
      "⏳ #{instance.name}: заказ №#{order["number"]} больше 5 минут не уходит в #{provider(order)}",
      order["branch"] && "Филиал: #{order["branch"]}",
      order["error"] && "Последняя ошибка: #{order["error"]}",
      "Попыток: #{order["attempts"]}"
    ])
  end

  defp lines(lines), do: lines |> Enum.reject(&is_nil/1) |> Enum.join("\n")

  def inserted_at(%{"inserted_at" => inserted_at}) when is_binary(inserted_at) do
    case NaiveDateTime.from_iso8601(inserted_at) do
      {:ok, at} -> DateTime.from_naive!(at, "Etc/UTC")
      _ -> nil
    end
  end

  def inserted_at(_order), do: nil

  defp recent?(order, now) do
    case inserted_at(order) do
      nil -> false
      at -> DateTime.diff(now, at) < @recovery_window_seconds
    end
  end

  defp notify(instance, text) do
    Alerts.send_message(text, %{
      reply_markup: Telegram.keyboard([[{"Открыть", "i:" <> instance.id}]])
    })
  end
end
