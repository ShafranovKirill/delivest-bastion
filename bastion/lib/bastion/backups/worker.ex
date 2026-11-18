defmodule Bastion.Backups.Worker do
  use Oban.Worker, queue: :backups, max_attempts: 1

  @impl Oban.Worker
  def perform(_job) do
    Bastion.Backups.run_daily()
    :ok
  end
end
