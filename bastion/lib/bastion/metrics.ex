defmodule Bastion.Metrics do
  import Ecto.Query, warn: false

  alias Bastion.Metrics.Sample
  alias Bastion.Repo

  @interval_seconds 60
  @periods [day: {86_400, 300}, week: {7 * 86_400, 1800}, month: {30 * 86_400, 7200}]

  def periods, do: Keyword.keys(@periods)

  def period_label(:day), do: "Сутки"
  def period_label(:week), do: "Неделя"
  def period_label(:month), do: "Месяц"

  def keep_days, do: Application.get_env(:bastion, :metrics_keep_days, 30)

  def record(instance_id, metrics, now \\ DateTime.utc_now(:second))

  def record(instance_id, %{} = metrics, now) do
    sample = sample(metrics)

    if (sample.cpu || sample.memory) && due?(instance_id, now),
      do: Repo.insert(struct(Sample, Map.merge(sample, %{instance_id: instance_id, at: now}))),
      else: :skipped
  end

  def record(_instance_id, _metrics, _now), do: :skipped

  def latest(instance_id) do
    Sample
    |> where([s], s.instance_id == ^instance_id)
    |> order_by([s], desc: s.at)
    |> limit(1)
    |> Repo.one()
  end

  def recent(instance_id, count) do
    Sample
    |> where([s], s.instance_id == ^instance_id)
    |> order_by([s], desc: s.at)
    |> limit(^count)
    |> Repo.all()
  end

  def series(instance_id, period, now \\ DateTime.utc_now(:second)) do
    {seconds, bucket} = Keyword.fetch!(@periods, period)
    from = DateTime.add(now, -seconds)
    origin = DateTime.to_naive(from)
    interval = %Postgrex.Interval{secs: bucket}

    buckets =
      from(s in Sample,
        where: s.instance_id == ^instance_id and s.at > ^from,
        select: %{
          at:
            type(
              fragment("date_bin(?, ?, ?)", ^interval, s.at, ^origin),
              :naive_datetime
            ),
          cpu: s.cpu,
          memory: s.memory
        }
      )

    from(b in subquery(buckets),
      group_by: b.at,
      order_by: b.at,
      select: %{at: b.at, cpu: avg(b.cpu), memory: avg(b.memory)}
    )
    |> Repo.all()
    |> Enum.map(&%{&1 | at: DateTime.from_naive!(&1.at, "Etc/UTC")})
    |> then(&%{from: from, to: now, points: &1})
  end

  def prune(now \\ DateTime.utc_now(:second)) do
    before = DateTime.add(now, -keep_days() * 86_400)
    {count, _} = Repo.delete_all(from(s in Sample, where: s.at < ^before))
    count
  end

  defp due?(instance_id, now) do
    since = DateTime.add(now, -(@interval_seconds - 5))
    not Repo.exists?(from(s in Sample, where: s.instance_id == ^instance_id and s.at > ^since))
  end

  defp sample(metrics) do
    memory =
      case metrics["memory"] do
        %{"total_kb" => total, "available_kb" => available}
        when is_integer(total) and total > 0 and is_integer(available) ->
          %{
            memory: Float.round(100 * (total - available) / total, 1),
            memory_used_kb: total - available,
            memory_total_kb: total
          }

        _ ->
          %{memory: nil, memory_used_kb: nil, memory_total_kb: nil}
      end

    Map.merge(memory, %{
      cpu: number(metrics["cpu_percent"]),
      load: number(List.first(List.wrap(metrics["load"]))),
      cpus: if(is_integer(metrics["cpus"]), do: metrics["cpus"])
    })
  end

  defp number(value) when is_number(value), do: value / 1
  defp number(_value), do: nil
end
