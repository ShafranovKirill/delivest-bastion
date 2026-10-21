defmodule Bastion.Downtime do
  import Ecto.Query, warn: false

  alias Bastion.Downtime.Incident
  alias Bastion.Instances.Instance
  alias Bastion.Repo

  @down_levels [:down, :offline]
  @periods [day: 86_400, week: 7 * 86_400, month: 30 * 86_400]

  def periods, do: Keyword.keys(@periods)

  @doc """
  Opens an incident when the instance goes down and closes it when it is back.
  A planned stop is not downtime, so it closes the incident too.
  """
  def track(%Instance{} = instance, %{level: level, problems: problems}, now \\ now()) do
    open = open_incident(instance.id)

    cond do
      level in @down_levels and is_nil(open) ->
        {:ok, incident} =
          Repo.insert(%Incident{
            instance_id: instance.id,
            level: to_string(level),
            problems: problems,
            started_at: now
          })

        {:opened, incident}

      level not in @down_levels and open ->
        {:ok, incident} = open |> Ecto.Changeset.change(ended_at: now) |> Repo.update()
        {:closed, incident}

      true ->
        :none
    end
  end

  def open_incident(instance_id) do
    Incident
    |> where([i], i.instance_id == ^instance_id and is_nil(i.ended_at))
    |> order_by([i], desc: i.started_at)
    |> limit(1)
    |> Repo.one()
  end

  def list_incidents(instance_id, limit \\ 10) do
    Incident
    |> where([i], i.instance_id == ^instance_id)
    |> order_by([i], desc: i.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Downtime and uptime percent for the last day, week and month."
  def summary(%Instance{} = instance, now \\ now()) do
    month_ago = DateTime.add(now, -Keyword.fetch!(@periods, :month))

    incidents =
      Incident
      |> where([i], i.instance_id == ^instance.id and i.started_at < ^now)
      |> where([i], is_nil(i.ended_at) or i.ended_at > ^month_ago)
      |> Repo.all()

    Map.new(@periods, fn {period, seconds} ->
      from = Enum.max([DateTime.add(now, -seconds), instance.inserted_at], DateTime)
      total = max(DateTime.diff(now, from), 1)
      down = incidents |> Enum.map(&overlap(&1, from, now)) |> Enum.sum()

      {period, %{down_seconds: down, uptime: Float.round(100 * (1 - down / total), 2)}}
    end)
  end

  def duration(%Incident{started_at: started, ended_at: ended}, now \\ now()),
    do: DateTime.diff(ended || now, started)

  def format_duration(seconds) when seconds < 60, do: "#{max(seconds, 0)} с"
  def format_duration(seconds) when seconds < 3600, do: "#{div(seconds, 60)} мин"

  def format_duration(seconds) when seconds < 86_400,
    do: join_units(div(seconds, 3600), "ч", div(rem(seconds, 3600), 60), "мин")

  def format_duration(seconds),
    do: join_units(div(seconds, 86_400), "дн", div(rem(seconds, 86_400), 3600), "ч")

  def format_period(:day), do: "24 ч"
  def format_period(:week), do: "7 дн"
  def format_period(:month), do: "30 дн"

  defp join_units(major, major_unit, 0, _minor_unit), do: "#{major} #{major_unit}"

  defp join_units(major, major_unit, minor, minor_unit),
    do: "#{major} #{major_unit} #{minor} #{minor_unit}"

  defp overlap(%Incident{started_at: started, ended_at: ended}, from, to) do
    started = Enum.max([started, from], DateTime)
    ended = Enum.min([ended || to, to], DateTime)
    max(DateTime.diff(ended, started), 0)
  end

  defp now, do: DateTime.utc_now(:second)
end
