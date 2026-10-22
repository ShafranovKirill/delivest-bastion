defmodule Bastion.Metrics.Alerts do
  alias Bastion.{Alerts, Instances, Metrics, Repo}
  alias Bastion.Instances.Instance

  @threshold 90
  @recovered_below 85
  @minutes 5
  @metrics [cpu: {"процессор загружен", "процессор"}, memory: {"память занята", "память"}]

  def threshold, do: @threshold
  def minutes, do: @minutes

  def check(instance_id, now \\ DateTime.utc_now(:second)) do
    with %Instance{} = instance <- Repo.get(Instance, instance_id),
         false <- Instances.busy?(instance_id) do
      samples = Metrics.recent(instance_id, @minutes)

      alerts =
        Enum.reduce(@metrics, instance.load_alerts, fn {metric, {label, name}}, alerts ->
          key = to_string(metric)
          recent = fresh(samples, now)
          values = Enum.map(recent, &Map.get(&1, metric))

          cond do
            not Map.has_key?(alerts, key) and high?(values) ->
              notify(
                instance,
                "🔥 #{instance.name}: #{label} на #{round(hd(values))}% уже #{@minutes} минут"
              )

              Map.put(alerts, key, DateTime.to_iso8601(List.last(recent).at))

            Map.has_key?(alerts, key) and recovered?(samples, metric) ->
              value = samples |> hd() |> Map.get(metric) |> round()
              notify(instance, "✅ #{instance.name}: #{name} снова в норме, #{value}%")
              Map.delete(alerts, key)

            true ->
              alerts
          end
        end)

      if alerts != instance.load_alerts,
        do: instance |> Ecto.Changeset.change(load_alerts: alerts) |> Repo.update(),
        else: :ok
    end
  end

  defp fresh([newest | _] = samples, now) do
    oldest = List.last(samples)

    if DateTime.diff(now, newest.at) <= 90 and
         DateTime.diff(newest.at, oldest.at) <= (@minutes - 1) * 60 + 30,
       do: samples,
       else: []
  end

  defp fresh([], _now), do: []

  defp high?(values),
    do: length(values) >= @minutes and Enum.all?(values, &(is_number(&1) and &1 > @threshold))

  defp recovered?(samples, metric) do
    values = samples |> Enum.take(2) |> Enum.map(&Map.get(&1, metric))
    length(values) == 2 and Enum.all?(values, &(is_number(&1) and &1 < @recovered_below))
  end

  defp notify(instance, text) do
    Alerts.send_message(text, %{
      reply_markup: Bastion.Telegram.keyboard([[{"Открыть", "i:" <> instance.id}]])
    })
  end
end
