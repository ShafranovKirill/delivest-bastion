defmodule Bastion.ManagedRollout.Worker do
  use Oban.Worker, queue: :managed_rollout, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"rollout_id" => id}}) do
    Bastion.ManagedRollout.advance(id)
  end

  def perform(_job) do
    Bastion.ManagedRollout.reconcile_paused()

    Bastion.ManagedRollout.running()
    |> case do
      %{status: "running", id: id} -> Bastion.ManagedRollout.advance(id)
      _ -> :ok
    end
  end
end
