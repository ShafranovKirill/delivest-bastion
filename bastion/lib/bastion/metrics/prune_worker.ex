defmodule Bastion.Metrics.PruneWorker do
  use Oban.Worker, queue: :checks, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    Bastion.Metrics.prune()
    :ok
  end
end
