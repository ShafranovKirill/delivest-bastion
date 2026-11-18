defmodule Bastion.Backups.CheckWorker do
  @moduledoc "Checks a stored backup with pg_restore and copies it to the offsite storage."

  use Oban.Worker, queue: :backups, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"backup_id" => id}}) do
    Bastion.Backups.check(id)
  end
end
