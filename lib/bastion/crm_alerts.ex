defmodule Bastion.CrmAlerts do
  alias Bastion.{Alerts, Repo}
  alias Bastion.Instances.Instance

  def problems(%Instance{status: %{"crm" => orders}} = instance) when is_list(orders),
    do: Enum.reject(orders, &(to_string(&1["id"]) in instance.crm_dismissed))

  def problems(_instance), do: []

  def dismiss(%Instance{} = instance, order_id) do
    reported =
      case instance.status do
        %{"crm" => orders} when is_list(orders) -> Enum.map(orders, &to_string(&1["id"]))
        _ -> []
      end

    dismissed =
      instance.crm_dismissed
      |> Enum.filter(&(&1 in reported))
      |> Enum.concat([to_string(order_id)])
      |> Enum.uniq()

    with {:ok, updated} <-
           instance |> Ecto.Changeset.change(crm_dismissed: dismissed) |> Repo.update() do
      updated = %{updated | online: instance.online}
      Phoenix.PubSub.broadcast(Bastion.PubSub, "instances", {:instance_updated, updated})
      {:ok, updated}
    end
  end

  def check(instance_id, orders)

  def check(instance_id, orders) when is_list(orders) do
    with %Instance{} = instance <- Repo.get(Instance, instance_id) do
      current = Map.new(orders, &{to_string(&1["id"]), &1})

      for {id, %{"status" => "failed"} = order} <- current,
          Map.get(instance.crm_alerts, id, %{})["status"] != "failed",
          id not in instance.crm_dismissed,
          do: notify(instance, id, message(instance, order))

      alerts =
        Map.new(current, fn {id, order} ->
          {id, Map.take(order, ["status", "number", "provider", "inserted_at"])}
        end)

      if alerts != instance.crm_alerts,
        do: instance |> Ecto.Changeset.change(crm_alerts: alerts) |> Repo.update(),
        else: :ok
    end
  end

  def check(_instance_id, _orders), do: :skipped

  def provider(%{"provider" => "frontpad"}), do: "Frontpad"
  def provider(%{"provider" => provider}) when is_binary(provider), do: provider
  def provider(_order), do: "CRM"

  defp message(instance, order) do
    [
      "🚨 #{instance.name}: заказ №#{order["number"]} не ушёл в #{provider(order)}",
      order["branch"] && "Филиал: #{order["branch"]}",
      order["error"] && "Ошибка: #{order["error"]}",
      "Попыток: #{order["attempts"]}",
      "Передайте заказ вручную."
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("\n")
  end

  def inserted_at(%{"inserted_at" => inserted_at}) when is_binary(inserted_at) do
    case NaiveDateTime.from_iso8601(inserted_at) do
      {:ok, at} -> DateTime.from_naive!(at, "Etc/UTC")
      _ -> nil
    end
  end

  def inserted_at(_order), do: nil

  defp notify(instance, order_id, text) do
    Alerts.notify(instance, text,
      buttons: [[{"🙈 Скрыть заказ", "cx:#{instance.id}:#{order_id}"}]]
    )
  end
end
