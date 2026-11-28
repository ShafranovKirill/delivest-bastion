defmodule Bastion.ManagedSnapshots.Worker do
  use Oban.Worker,
    queue: :backups,
    max_attempts: 12,
    unique: [
      fields: [:args],
      keys: [:instance_id],
      states: [:available, :scheduled, :executing, :retryable],
      period: 86_400
    ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => id}}) do
    with %{transport: "node"} = instance <- Bastion.Instances.get_instance(id),
         %Bastion.Nodes.Placement{} <- Bastion.Nodes.placement_for(id) do
      latest = Bastion.ManagedSnapshots.latest(id)

      if latest && DateTime.to_date(latest.finished_at) == Date.utc_today() do
        :ok
      else
        case Bastion.ManagedSnapshots.start(instance, "расписание") do
          {:ok, _} -> :ok
          {:error, :placement_not_found} -> :ok
          {:error, reason} when reason in [:busy, :offline] -> {:snooze, 300}
          {:error, reason} -> {:error, reason}
        end
      end
    else
      _ -> :ok
    end
  end

  def perform(_), do: Bastion.Snapshots.run_daily()
end
