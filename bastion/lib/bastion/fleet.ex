defmodule Bastion.Fleet do
  @moduledoc "Shared operational status for the web panel and Telegram."

  import Ecto.Query

  alias Bastion.{Alerts, Instances, ManagedSnapshots, Nodes, Repo}
  alias Bastion.Fleet.Incident
  alias Bastion.Maintenance
  alias Bastion.Nodes.Node
  alias Bastion.Snapshots.Snapshot

  def node_resources(node, now \\ DateTime.utc_now()) do
    settings = Application.get_env(:bastion, :fleet, [])
    fresh = fresh?(node.sampled_at, now, settings[:metrics_seconds] || 90)
    cpu = node.metrics["cpu_percent"]
    ram = get_in(node.metrics, ["memory", "available_kb"])

    disk =
      node.metrics["disks"]
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"free_kb" => value} when is_number(value) -> [value]
        _ -> []
      end)
      |> Enum.min(fn -> nil end)

    warnings =
      if fresh do
        [
          is_number(cpu) and cpu >= (settings[:cpu_percent] || 90) && "Высокая загрузка CPU",
          is_number(ram) and ram < (settings[:ram_kib] || 524_288) && "Мало свободной RAM",
          is_number(disk) and disk < (settings[:disk_kib] || 5_242_880) && "Мало места на диске"
        ]
        |> Enum.filter(&is_binary/1)
      else
        ["Нет свежих показателей ресурсов"]
      end

    %{
      connected: connected?(node, now),
      fresh: fresh,
      cpu: cpu,
      ram: ram,
      disk: disk,
      warnings: warnings
    }
  end

  def connected?(node, now \\ DateTime.utc_now())
  def connected?(nil, _now), do: false

  def connected?(node, now) do
    is_nil(node.credential_revoked_at) and not is_nil(node.credential_hash) and
      fresh?(node.last_seen_at, now, 90)
  end

  def public_state(instance, kind, now \\ DateTime.utc_now()) do
    cond do
      instance.desired_state == "stopped" or not is_nil(instance.stopped_at) -> :stopped
      Maintenance.active?(instance, now) -> :maintenance
      not fresh?(instance.checked_at, now, 180) -> :unknown
      get_in(instance.external || %{}, [kind, "ok"]) == true -> :ok
      get_in(instance.external || %{}, [kind, "ok"]) == false -> :down
      true -> :unknown
    end
  end

  def instance(instance, now \\ DateTime.utc_now()) do
    placement = Nodes.placement_for(instance.id)
    checked = ManagedSnapshots.last_restore_checked(instance.id)
    latest = ManagedSnapshots.latest(instance.id)

    %{
      site: public_state(instance, "site", now),
      api: public_state(instance, "api", now),
      placement: placement,
      connected: placement && connected?(placement.node, now),
      operation: List.first(Nodes.operations_for(instance.id)),
      backup: backup_state(latest, checked, now),
      checked_backup: checked,
      latest_backup: latest
    }
  end

  def backup_state(latest, checked, now \\ DateTime.utc_now()) do
    settings = Application.get_env(:bastion, :fleet, [])
    max_age = settings[:backup_seconds] || 129_600

    cond do
      is_nil(latest) -> :missing
      not fresh?(latest.finished_at, now, max_age) -> :stale
      is_nil(checked) -> :unverified
      not fresh?(checked.finished_at, now, max_age) -> :stale_verified
      true -> :ok
    end
  end

  def label(:ok), do: "Работает"
  def label(:down), do: "Недоступно"
  def label(:unknown), do: "Нет свежих данных"
  def label(:stopped), do: "Плановая остановка"
  def label(:maintenance), do: "Обслуживание"
  def label(:missing), do: "Нет полной копии"
  def label(:stale), do: "Полная копия устарела"
  def label(:unverified), do: "Восстановление ещё не проверено"
  def label(:stale_verified), do: "Проверенная точка восстановления устарела"

  def time(nil), do: "Нет данных"
  def time(at), do: Calendar.strftime(at, "%d.%m.%Y %H:%M UTC")

  def capacity(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1_048_576, decimals: 1) <> " ГиБ"

  def capacity(_), do: "Нет данных"

  def certificate_warnings(instances, now \\ DateTime.utc_now()) do
    for instance <- instances,
        fresh?(instance.checked_at, now, 180),
        {kind, %{"cert_expires_at" => expiry}} when is_binary(expiry) <- instance.external || %{},
        {:ok, expires_at, _} <- [DateTime.from_iso8601(expiry)],
        seconds = DateTime.diff(expires_at, now),
        seconds < 14 * 86_400,
        do: {instance, kind, expires_at}
  end

  def backup_warnings(instances, now \\ DateTime.utc_now()) do
    managed = Enum.filter(instances, &(&1.transport == "node" and &1.desired_state == "running"))
    ids = Enum.map(managed, & &1.id)
    latest = snapshot_index(ids, false)
    checked = snapshot_index(ids, true)

    for instance <- managed,
        state = backup_state(latest[instance.id], checked[instance.id], now),
        state != :ok,
        do: {instance, state}
  end

  def recent_incidents(limit \\ 10) do
    Repo.all(from i in Incident, order_by: [desc: i.started_at], preload: :node, limit: ^limit)
  end

  def incident_label("shared_outage"), do: "Общий сбой сайтов"
  def incident_label("management"), do: "Нет связи с нодой"
  def incident_label("containers"), do: "Повторяющиеся сбои контейнеров"

  def reconcile(now \\ DateTime.utc_now()) do
    installed =
      Instances.list_instances()
      |> Map.new(&{&1.id, &1})

    by_node = Nodes.active_placements() |> Map.values() |> Enum.group_by(& &1.node_id)

    Enum.each(Nodes.list_nodes(), fn node ->
      placements = Map.get(by_node, node.id, [])
      instances = Enum.flat_map(placements, &List.wrap(installed[&1.instance_id]))
      incident = incident_for(node, instances, placements, now)
      reconcile_incident(node, incident, now)
      site_alerts(instances, incident, now)
    end)

    backup_alerts(Map.values(installed), now)
  end

  defp incident_for(node, instances, placements, now) do
    down =
      Enum.filter(instances, &(&1.health == "down" and public_state(&1, "site", now) == :down))

    running = Enum.filter(instances, &(&1.desired_state == "running"))

    degraded_ids =
      for placement <- placements,
          fresh?(placement.observed_at, now, 90),
          Enum.any?(placement.restart_guard, &(&1["state"] == "tripped")),
          do: placement.instance_id

    degraded = Enum.filter(running, &(&1.id in degraded_ids))

    cond do
      length(down) >= 2 -> {"shared_outage", down}
      node.last_seen_at && !connected?(node, now) -> {"management", instances}
      degraded != [] -> {"containers", degraded}
      true -> nil
    end
  end

  defp reconcile_incident(node, incident, now) do
    result =
      Repo.transaction(fn ->
        Repo.one!(from n in Node, where: n.id == ^node.id, lock: "FOR UPDATE")
        open = Repo.one(from i in Incident, where: i.node_id == ^node.id and is_nil(i.ended_at))

        case {open, incident} do
          {nil, nil} ->
            :unchanged

          {%Incident{} = previous, nil} ->
            previous |> Ecto.Changeset.change(ended_at: now) |> Repo.update!()
            :closed

          {previous, {kind, instances}} ->
            affected = Map.new(instances, &{&1.id, &1.name})

            if previous do
              previous |> Ecto.Changeset.change(kind: kind, affected: affected) |> Repo.update!()
              :unchanged
            else
              Repo.insert!(%Incident{
                node_id: node.id,
                kind: kind,
                affected: affected,
                started_at: now
              })

              {:opened, kind, affected}
            end
        end
      end)

    if Application.get_env(:bastion, :fleet, [])[:notify] do
      case result do
        {:ok, {:opened, kind, affected}} ->
          names =
            affected |> Map.values() |> Enum.sort() |> Enum.join(", ") |> String.slice(0, 3000)

          Alerts.send_message(Enum.join([node.name, incident_label(kind), names], "\n"))

        {:ok, :closed} ->
          Alerts.send_message("#{node.name}\nИнцидент устранён")

        _ ->
          :ok
      end
    end
  end

  defp site_alerts(instances, incident, now) do
    if Application.get_env(:bastion, :fleet, [])[:notify] do
      grouped = match?({"shared_outage", _}, incident)

      Enum.each(instances, fn instance ->
        state = public_state(instance, "site", now)
        api = public_state(instance, "api", now)

        cond do
          grouped or (state in [:ok, :stopped, :maintenance] and api != :down) ->
            Alerts.notify_once(instance, "managed_site", nil)

          instance.health == "down" and :down in [state, api] ->
            Alerts.notify_once(
              instance,
              "managed_site",
              "#{instance.name}\nВитрина: #{label(state)} · API: #{label(api)}"
            )

          true ->
            :ok
        end
      end)
    end
  end

  defp backup_alerts(instances, now) do
    if Application.get_env(:bastion, :fleet, [])[:notify] do
      managed =
        Enum.filter(instances, &(&1.transport == "node" and &1.desired_state == "running"))

      ids = Enum.map(managed, & &1.id)
      latest = snapshot_index(ids, false)
      checked = snapshot_index(ids, true)

      Enum.each(managed, fn instance ->
        state = backup_state(latest[instance.id], checked[instance.id], now)

        if state in [:ok, :stale, :stale_verified] do
          Alerts.notify_once(
            instance,
            "managed_backup",
            if(state == :ok, do: nil, else: "#{instance.name}\n#{label(state)}")
          )
        end
      end)
    end
  end

  defp snapshot_index(instance_ids, restored) do
    query =
      from s in Snapshot,
        where:
          s.instance_id in ^instance_ids and s.status == "ok" and s.kind == "full" and
            not is_nil(s.node_operation_id),
        distinct: s.instance_id,
        order_by: [desc: s.finished_at, desc: s.id]

    query = if restored, do: where(query, [s], not is_nil(s.restore_checked_at)), else: query
    query |> Repo.all() |> Map.new(&{&1.instance_id, &1})
  end

  defp fresh?(nil, _now, _seconds), do: false

  defp fresh?(at, now, seconds) do
    age = DateTime.diff(now, at)
    age >= -30 and age < seconds
  end
end
