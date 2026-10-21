defmodule Bastion.Checks.Worker do
  use Oban.Worker, queue: :checks, max_attempts: 1

  alias Bastion.{Alerts, Health, Instances}
  alias Bastion.Checks.External

  @impl Oban.Worker
  def perform(_job) do
    Instances.list_instances()
    |> Task.async_stream(&check/1, timeout: 60_000, on_timeout: :kill_task, max_concurrency: 10)
    |> Stream.run()
  end

  def check(instance) do
    external = External.run(instance.hosts)
    health = Health.evaluate(%{instance | external: external})
    previous = instance.health

    {:ok, updated} = Instances.update_checks(instance, external, health.level)
    if to_string(health.level) != previous, do: Alerts.health_changed(updated, previous, health)
    updated
  end
end
