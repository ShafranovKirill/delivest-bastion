defmodule Bastion.SiteAlerts do
  @moduledoc """
  Problems that a working site does not show by its HTTP status: no orders when they
  usually come, a burst of application errors, a container that keeps crashing and a
  disk that is about to fill up. Each one is reported once and once more when it is over.
  """

  alias Bastion.{Alerts, Instances, Repo}
  alias Bastion.Instances.Instance

  @min_usual_orders 3
  @errors_threshold 20
  @errors_recovered_below 5
  @disk_threshold 95
  @disk_recovered_below 92
  @crash_quiet_seconds 30 * 60

  def min_usual_orders, do: @min_usual_orders
  def errors_threshold, do: @errors_threshold
  def disk_threshold, do: @disk_threshold

  def check(previous, status, now \\ DateTime.utc_now(:second))

  def check(%Instance{stopped_at: nil} = previous, %{} = status, now) do
    busy? = Instances.busy?(previous.id)

    alerts =
      previous.site_alerts
      |> orders(previous, status["orders"], now)
      |> errors(previous, status["errors"], now)
      |> disk(previous, status, now)
      |> crashes(previous, status["containers"], busy?, now)

    if alerts != previous.site_alerts do
      with {:ok, updated} <-
             previous |> Ecto.Changeset.change(site_alerts: alerts) |> Repo.update() do
        Phoenix.PubSub.broadcast(Bastion.PubSub, "instances", {:instance_updated, updated})
        {:ok, updated}
      end
    else
      :ok
    end
  end

  def check(_previous, _status, _now), do: :skipped

  def describe({"orders", alert}),
    do: "Нет заказов с #{since(alert)}, обычно около #{alert["usual"]} в час"

  def describe({"errors", alert}),
    do: "#{alert["count"]} ошибок приложения за 5 минут с #{since(alert)}"

  def describe({"disk", alert}), do: "Диск заполнен на #{alert["percent"]}% с #{since(alert)}"

  def describe({"crash:" <> service, alert}),
    do:
      "Контейнер #{service} падал, последний раз #{since(alert)}, всего #{alert["restarts"]} раз"

  def describe({key, _alert}), do: key

  def label("orders"), do: "Нет заказов"
  def label("errors"), do: "Ошибки"
  def label("disk"), do: "Диск"
  def label("crash:" <> service), do: "Падает #{service}"
  def label(key), do: key

  defp orders(alerts, instance, %{"last_hour" => count, "usual" => usual}, now)
       when is_integer(count) and is_number(usual) do
    active? = Map.has_key?(alerts, "orders")

    cond do
      not active? and count == 0 and usual >= @min_usual_orders ->
        notify(
          instance,
          "🛒 #{instance.name}: за последний час ни одного заказа, а обычно в это время около #{format(usual)}.\n" <>
            "Проверьте, что сайт принимает заказы и оплату."
        )

        Map.put(alerts, "orders", %{"since" => iso(now), "usual" => format(usual)})

      active? and count > 0 ->
        notify(instance, "✅ #{instance.name}: заказы снова идут, за последний час #{count}")
        Map.delete(alerts, "orders")

      true ->
        alerts
    end
  end

  defp orders(alerts, _instance, _orders, _now), do: alerts

  defp errors(alerts, instance, %{"last_5m" => count} = errors, now) when is_integer(count) do
    active? = Map.has_key?(alerts, "errors")

    cond do
      not active? and count >= @errors_threshold ->
        latest =
          case errors["latest"] do
            [%{"message" => message} | _] -> "\nПоследняя: " <> String.slice(message, 0, 300)
            _ -> ""
          end

        notify(instance, "🐞 #{instance.name}: #{count} ошибок в приложении за 5 минут" <> latest)
        Map.put(alerts, "errors", %{"since" => iso(now), "count" => count})

      active? and count < @errors_recovered_below ->
        notify(instance, "✅ #{instance.name}: ошибок стало меньше, #{count} за 5 минут")
        Map.delete(alerts, "errors")

      true ->
        alerts
    end
  end

  defp errors(alerts, _instance, _errors, _now), do: alerts

  defp disk(
         alerts,
         instance,
         %{"disk" => %{"used_kb" => used, "total_kb" => total} = disk} = status,
         now
       )
       when is_integer(used) and is_integer(total) and total > 0 do
    percent = round(used / total * 100)
    active? = Map.has_key?(alerts, "disk")

    cond do
      not active? and percent >= @disk_threshold ->
        database =
          case status["database"] do
            %{"size_bytes" => bytes} when is_integer(bytes) ->
              " База занимает #{gigabytes(bytes / 1024)}."

            _ ->
              ""
          end

        notify(
          instance,
          "💽 #{instance.name}: диск заполнен на #{percent}%, свободно #{gigabytes(disk["free_kb"] || total - used)}." <>
            database
        )

        Map.put(alerts, "disk", %{"since" => iso(now), "percent" => percent})

      active? and percent < @disk_recovered_below ->
        notify(instance, "✅ #{instance.name}: место на диске освободилось, занято #{percent}%")
        Map.delete(alerts, "disk")

      true ->
        alerts
    end
  end

  defp disk(alerts, _instance, _status, _now), do: alerts

  # Docker counts only the restarts it made itself after a crash; a restart or an update
  # from the bastion does not add to it, and recreating a container starts it from zero.
  defp crashes(alerts, instance, containers, busy?, now) when is_list(containers) do
    before = restarts(instance.status)

    alerts =
      Map.reject(alerts, fn {key, alert} ->
        String.starts_with?(key, "crash:") and
          DateTime.diff(now, parse(alert["at"]) || now) > @crash_quiet_seconds
      end)

    for %{"service" => service, "restarts" => restarts} <- containers,
        is_integer(restarts),
        not busy?,
        is_integer(before[service]) and restarts > before[service],
        reduce: alerts do
      alerts ->
        key = "crash:" <> service

        unless Map.has_key?(alerts, key) do
          notify(
            instance,
            "💥 #{instance.name}: контейнер #{service} упал и перезапустился (всего #{restarts} раз). " <>
              "Посмотрите его логи."
          )
        end

        Map.put(alerts, key, %{"at" => iso(now), "restarts" => restarts})
    end
  end

  defp crashes(alerts, _instance, _containers, _busy?, _now), do: alerts

  defp restarts(%{"containers" => containers}) when is_list(containers),
    do: Map.new(containers, &{&1["service"], &1["restarts"]})

  defp restarts(_status), do: %{}

  defp notify(instance, text), do: Alerts.notify(instance, text)

  defp since(%{"since" => at}), do: format_time(at)
  defp since(%{"at" => at}), do: format_time(at)
  defp since(_alert), do: "—"

  defp format_time(at) do
    case parse(at) do
      nil -> to_string(at)
      at -> Calendar.strftime(at, "%d.%m %H:%M UTC")
    end
  end

  defp parse(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, at, _offset} -> at
      _ -> nil
    end
  end

  defp parse(_at), do: nil

  defp format(number) when is_float(number) and number == trunc(number), do: trunc(number)
  defp format(number), do: number

  defp gigabytes(kb), do: :erlang.float_to_binary(kb / 1_048_576, decimals: 1) <> " ГБ"

  defp iso(now), do: DateTime.to_iso8601(now)
end
