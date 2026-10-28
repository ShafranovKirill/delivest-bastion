defmodule Bastion.Instances.ExpireWorker do
  use Oban.Worker, queue: :checks, max_attempts: 1

  @impl Oban.Worker
  def perform(_job), do: Bastion.Instances.expire_commands()
end
