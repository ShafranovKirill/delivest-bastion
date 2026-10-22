defmodule Bastion.Checks.Worker do
  use Oban.Worker, queue: :checks, max_attempts: 1

  alias Bastion.{Alerts, Downtime, Health, Instances}
  alias Bastion.Checks.External

  @impl Oban.Worker
  def perform(_job) do
    Instances.list_instances()
    |> Task.async_stream(&check/1, timeout: 60_000, on_timeout: :kill_task, max_concurrency: 10)
    |> Stream.run()
  end

  def check(instance, now \\ DateTime.utc_now(:second)) do
    external = External.run(instance.hosts)

    if Instances.busy?(instance.id) do
      {:ok, updated} = Instances.update_checks(instance, external, instance.health)
      updated
    else
      health = Health.evaluate(%{instance | external: external})
      down_since = if health.level == :down, do: instance.down_since || now

      if confirmed?(health, instance.down_since, now),
        do: apply_health(instance, external, health, down_since, now),
        else: elem(Instances.update_checks(instance, external, instance.health, down_since), 1)
    end
  end

  defp confirmed?(%{level: :down}, nil, _now), do: false

  defp confirmed?(%{level: :down}, down_since, now),
    do: DateTime.diff(now, down_since) >= Application.get_env(:bastion, :down_confirm_seconds, 50)

  defp confirmed?(_health, _down_since, _now), do: true

  defp apply_health(instance, external, health, down_since, now) do
    previous = instance.health

    {:ok, updated} = Instances.update_checks(instance, external, health.level, down_since)
    downtime = Downtime.track(updated, health, down_since || now)

    if to_string(health.level) != previous,
      do: Alerts.health_changed(updated, previous, health, downtime)

    updated
  end
end
