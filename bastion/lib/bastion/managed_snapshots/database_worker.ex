defmodule Bastion.ManagedSnapshots.DatabaseWorker do
  use Oban.Worker,
    queue: :backups,
    max_attempts: 5,
    unique: [fields: [:args], states: [:available, :scheduled, :executing, :retryable]]

  alias Bastion.{Instances, ManagedSnapshots, Nodes}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"instance_id" => id}}) do
    with true <- enabled?(),
         %{transport: "node", desired_state: "running"} = instance <- Instances.get_instance(id),
         %{observed_state: "running"} <- Nodes.placement_for(id) do
      case ManagedSnapshots.start_database(instance, "расписание") do
        {:ok, _backup} -> :ok
        {:error, :placement_not_found} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> :ok
    end
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    if enabled?() do
      for %{transport: "node", desired_state: "running", id: id} <- Instances.list_instances() do
        %{instance_id: id} |> new() |> Oban.insert()
      end
    end

    :ok
  end

  defp enabled?, do: Application.get_env(:bastion, :managed_postgres_backups, false)
end
