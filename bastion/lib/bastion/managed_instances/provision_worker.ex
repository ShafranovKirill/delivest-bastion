defmodule Bastion.ManagedInstances.ProvisionWorker do
  use Oban.Worker, queue: :default, max_attempts: 1

  @impl true
  def perform(%Oban.Job{args: %{"operation_id" => id}}) do
    case Bastion.ManagedInstances.advance(id) do
      {:error, _} -> :ok
      _ -> :ok
    end
  end
end
