defmodule Bastion.Maintenance do
  import Ecto.Query, warn: false

  alias Bastion.Downtime
  alias Bastion.Instances
  alias Bastion.Instances.Instance
  alias Bastion.Maintenance.Window
  alias Bastion.Repo

  @durations [15, 30, 60, 120]

  def durations, do: @durations

  def active?(%Instance{maintenance_until: nil}, _now), do: false
  def active?(%Instance{maintenance_until: until}, now), do: DateTime.compare(until, now) == :gt
  def active?(%Instance{} = instance), do: active?(instance, now())

  def start(%Instance{} = instance, minutes \\ 30, at \\ now()) do
    if minutes in @durations do
      Repo.transaction(fn ->
        current = lock_instance!(instance.id)

        if active?(current, at) do
          current
        else
          until = DateTime.add(at, minutes * 60)

          Repo.insert!(%Window{
            instance_id: current.id,
            started_at: at,
            scheduled_end_at: until
          })

          Downtime.track(current, %{level: :maintenance, problems: []}, at)

          current
          |> Ecto.Changeset.change(maintenance_until: until, down_since: nil)
          |> Repo.update!()
        end
      end)
      |> broadcast_result()
    else
      {:error, :invalid_duration}
    end
  end

  def finish(%Instance{} = instance, at \\ now()) do
    Repo.transaction(fn ->
      current = lock_instance!(instance.id)

      if current.maintenance_until do
        open_window =
          Window
          |> where([w], w.instance_id == ^current.id and is_nil(w.ended_at))
          |> order_by([w], desc: w.started_at)
          |> limit(1)
          |> Repo.one()

        if open_window do
          ended_at = Enum.min([at, open_window.scheduled_end_at], DateTime)
          ended_at = Enum.max([ended_at, open_window.started_at], DateTime)
          open_window |> Ecto.Changeset.change(ended_at: ended_at) |> Repo.update!()
        end

        current
        |> Ecto.Changeset.change(maintenance_until: nil, down_since: nil)
        |> Repo.update!()
      else
        current
      end
    end)
    |> broadcast_result()
  end

  def windows(%Instance{id: id}, limit \\ 10) do
    Window
    |> where([w], w.instance_id == ^id)
    |> order_by([w], desc: w.started_at)
    |> limit(^limit)
    |> Repo.all()
  end

  def intervals(instance_id, from, to) do
    Window
    |> where([w], w.instance_id == ^instance_id and w.started_at < ^to)
    |> where([w], w.scheduled_end_at > ^from)
    |> where([w], is_nil(w.ended_at) or w.ended_at > ^from)
    |> Repo.all()
    |> Enum.map(fn w ->
      {Enum.max([w.started_at, from], DateTime),
       Enum.min([w.ended_at || w.scheduled_end_at, w.scheduled_end_at, to], DateTime)}
    end)
    |> Enum.filter(fn {start_at, end_at} -> DateTime.compare(end_at, start_at) == :gt end)
    |> Enum.sort_by(fn {start_at, _} -> DateTime.to_unix(start_at) end)
    |> Enum.reduce([], fn {start_at, end_at}, acc ->
      case acc do
        [{prior_start, prior_end} | rest] ->
          if DateTime.compare(start_at, prior_end) != :gt do
            [{prior_start, Enum.max([prior_end, end_at], DateTime)} | rest]
          else
            [{start_at, end_at} | acc]
          end

        _ ->
          [{start_at, end_at} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp lock_instance!(id) do
    case Instance |> where([i], i.id == ^id) |> lock("FOR UPDATE") |> Repo.one() do
      nil -> Repo.rollback(:not_found)
      instance -> instance
    end
  end

  defp broadcast_result({:ok, instance}) do
    Instances.broadcast_instance(instance)
    {:ok, instance}
  end

  defp broadcast_result(error), do: error

  defp now, do: DateTime.utc_now(:second)
end
