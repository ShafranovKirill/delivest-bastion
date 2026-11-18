defmodule Bastion.Snapshots.Worker do
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
    case Bastion.Instances.get_instance(id) do
      nil ->
        :ok

      instance ->
        latest = Bastion.Snapshots.latest(instance.id)

        if latest && DateTime.to_date(latest.finished_at) == Date.utc_today() do
          :ok
        else
          case Bastion.Snapshots.start(instance, "расписание") do
            {:ok, _} -> :ok
            {:error, reason} when reason in [:busy, :offline] -> {:snooze, 300}
            {:error, :storage_unavailable} -> {:error, :storage_unavailable}
            _ -> :ok
          end
        end
    end
  end

  def perform(_job), do: Bastion.Snapshots.run_daily()
end
