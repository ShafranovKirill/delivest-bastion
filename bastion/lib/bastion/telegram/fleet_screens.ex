defmodule Bastion.Telegram.FleetScreens do
  import Bastion.Telegram, only: [escape: 1]

  alias Bastion.{Fleet, Health, Instances, Nodes, Releases}

  def menu do
    [
      [{"Обзор", "fleet"}, {"Франшизы", "l"}],
      [{"Серверы", "servers"}, {"Операции", "operations"}]
    ]
  end

  def overview do
    instances = Instances.list_instances()
    nodes = Nodes.list_nodes()
    down = Enum.count(instances, &(Health.evaluate(&1).level == :down))
    offline = Enum.count(nodes, &(not Fleet.connected?(&1)))

    incidents =
      for incident <- Fleet.recent_incidents(5), is_nil(incident.ended_at) do
        affected = incident.affected |> Map.values() |> Enum.sort() |> Enum.join(", ")
        escape("#{incident.node.name} · #{Fleet.incident_label(incident.kind)} · #{affected}")
      end

    {Enum.join(
       [
         "<b>Обзор</b>",
         "Франшиз #{length(instances)} · с ошибками #{down}",
         "Серверов #{length(nodes)} · без связи #{offline}" | incidents
       ],
       "\n"
     ), menu()}
  end

  def servers do
    nodes = Nodes.list_nodes()

    buttons =
      nodes
      |> Enum.map(&{"#{if Fleet.connected?(&1), do: "🟢", else: "⚫"} #{&1.name}", "n:" <> &1.id})
      |> Enum.take(80)
      |> Enum.chunk_every(2)

    {"<b>Серверы</b> · #{length(nodes)}", buttons ++ [[web("Все серверы", "/nodes")]] ++ menu()}
  end

  def node(node) do
    resources = Fleet.node_resources(node)
    placements = Enum.filter(Nodes.list_placements(node.id), &(&1.state == "active"))
    cpu = if is_number(resources.cpu), do: "#{resources.cpu}%", else: "нет данных"

    lines =
      [
        "<b>#{escape(node.name)}</b>",
        if(resources.connected, do: "Нода на связи", else: "Нет связи с нодой"),
        "Heartbeat · #{Fleet.time(node.last_seen_at)}",
        "Показатели · #{Fleet.time(node.sampled_at)}#{if resources.fresh, do: "", else: " · устарели"}",
        "CPU #{cpu} · RAM #{Fleet.capacity(resources.ram)} · диск #{Fleet.capacity(resources.disk)}",
        if(node.maintenance, do: "Режим обслуживания"),
        "Франшизы · #{length(placements)}"
      ]
      |> Enum.reject(&is_nil/1)

    buttons =
      placements
      |> Enum.take(60)
      |> Enum.map(&{&1.instance.name, "i:" <> &1.instance_id})
      |> Enum.chunk_every(2)

    {Enum.join(lines, "\n"),
     buttons ++
       [[{"Обновить данные", "n:" <> node.id}, web("Открыть в Bastion", "/nodes/" <> node.id)]] ++
       menu()}
  end

  def instance(instance, notice \\ nil, version \\ :fetch, selected_operation \\ nil) do
    state = Fleet.instance(instance)

    version =
      case version do
        :fetch ->
          case Releases.Managed.latest() do
            {:ok, release} -> release.version
            _ -> nil
          end

        known ->
          known
      end

    installed = state.placement && state.placement.observed_release
    operation = selected_operation || state.operation

    lines =
      [
        "<b>#{escape(instance.name)}</b>",
        "Витрина · #{Fleet.label(state.site)}",
        "API · #{Fleet.label(state.api)}",
        "Проверено · #{Fleet.time(instance.checked_at)}",
        if(state.connected, do: "Нода на связи", else: "Нет связи с нодой"),
        "Установлен #{escape(installed || "—")} · опубликован #{escape(version || "—")}",
        "Резервная копия · #{if state.backup == :ok, do: "Актуальна", else: Fleet.label(state.backup)}",
        if(state.latest_backup, do: "Копия от #{Fleet.time(state.latest_backup.finished_at)}"),
        operation && "Последняя операция · #{operation_text(operation)}",
        notice && escape(notice)
      ]
      |> Enum.reject(&is_nil/1)

    update =
      if state.placement do
        [{"Обновить Delivest", "ma:" <> instance.id}]
      else
        []
      end

    {Enum.join(lines, "\n"),
     [
       [{"Обновить данные", "i:" <> instance.id} | update],
       [web("Открыть в Bastion", "/instances/" <> instance.id)]
     ] ++ menu()}
  end

  def confirm(instance, release, token) do
    {"<b>Обновить Delivest</b>\n#{escape(instance.name)} · v#{escape(release.version)}",
     [[{"Подтвердить", "my:" <> token}, {"Назад", "i:" <> instance.id}]]}
  end

  def operations do
    entries =
      for operation <- Nodes.list_operations(12) do
        name = (operation.instance && operation.instance.name) || operation.node.name
        "#{Fleet.time(operation.inserted_at)} · #{escape(name)} · #{operation_text(operation)}"
      end

    text = ["<b>Операции</b>" | entries] |> Enum.join("\n") |> String.slice(0, 3500)
    {text, [[{"Обновить данные", "operations"}, web("Журнал Bastion", "/operations")]] ++ menu()}
  end

  def operation_text(operation) do
    action = Instances.action_label(operation.action)

    status =
      case operation.status do
        "pending" -> "В очереди"
        "running" -> "Выполняется"
        "waiting_external" -> "Ожидает внешней проверки"
        "unknown" -> "Результат уточняется после сверки с нодой"
        "ok" -> "Успешно"
        "error" -> "Ошибка"
        other -> other
      end

    label = if operation.action == "instance_update", do: "Обновление Delivest", else: action
    details = operation.result["reason"] || operation.progress["stage"]

    [label, status, details && String.slice(to_string(details), 0, 140)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(" · ", &escape/1)
  end

  defp web(label, path), do: {label, {:url, BastionWeb.Endpoint.url() <> path}}
end
