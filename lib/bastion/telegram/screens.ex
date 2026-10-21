defmodule Bastion.Telegram.Screens do
  @moduledoc "Texts and inline keyboards of the bot, in Telegram HTML."

  import Bastion.Telegram, only: [escape: 1]

  alias Bastion.{Downtime, Health, Instances}
  alias Bastion.Instances.Instance

  @levels %{
    ok: {"🟢", "работает"},
    warning: {"🟡", "есть предупреждения"},
    down: {"🔴", "ошибки"},
    offline: {"⚫", "агент не на связи"},
    stopped: {"⏸", "выключен по плану"},
    unknown: {"❔", "нет данных"}
  }

  @confirm %{
    "update" => "Скачать новые образы и перезапустить",
    "restart" => "Перезапустить",
    "stop" => "Выключить"
  }

  def confirm?(action), do: Map.has_key?(@confirm, action)

  def menu do
    instances = Instances.list_instances()
    counts = instances |> Enum.map(&Health.evaluate(&1).level) |> Enum.frequencies()

    summary =
      [:ok, :warning, :down, :offline, :stopped, :unknown]
      |> Enum.filter(&Map.has_key?(counts, &1))
      |> Enum.map_join(" · ", fn level -> "#{emoji(level)} #{counts[level]}" end)

    text = """
    <b>Delivest Bastion</b>
    Сетей: #{length(instances)}, на связи #{Enum.count(instances, & &1.online)}
    #{summary}
    """

    {text,
     [
       [{"🏪 Сети", "l"}, {"📉 Простой", "d"}],
       [{"🔄 Обновить", "m"}]
     ]}
  end

  def instances do
    instances = Instances.list_instances()

    lines =
      Enum.map(instances, fn instance ->
        %{level: level} = Health.evaluate(instance)
        "#{emoji(level)} <b>#{escape(instance.name)}</b> — #{label(level)}"
      end)

    text =
      case lines do
        [] -> "Пока ни один агент не подключился."
        lines -> Enum.join(["<b>Сети</b>" | lines], "\n")
      end

    buttons =
      Enum.map(instances, fn instance ->
        [{"#{emoji(Health.evaluate(instance).level)} #{instance.name}", "i:" <> instance.id}]
      end)

    {text, buttons ++ [[{"⬅️ Меню", "m"}, {"🔄 Обновить", "l"}]]}
  end

  def instance(%Instance{} = instance) do
    health = Health.evaluate(instance)
    status = instance.status || %{}
    uptime = Downtime.summary(instance)
    running = Instances.running_command(instance.id)

    text =
      [
        "#{emoji(health.level)} <b>#{escape(instance.name)}</b> — #{label(health.level)}",
        hosts(instance),
        "Агент: #{if instance.online, do: "на связи", else: "не на связи"}, " <>
          "#{ago(instance.last_seen_at)} · версия #{escape(instance.agent_version || "—")}",
        running && "⏳ Выполняется: #{Instances.action_label(running.action)}",
        instance.stopped_at && "⏸ Выключен по плану #{datetime(instance.stopped_at)}",
        section("Проблемы", Enum.map(health.problems, &("• " <> escape(&1)))),
        section("Контейнеры", Enum.map(List.wrap(status["containers"]), &container/1)),
        section("Проверки", checks(instance)),
        "",
        disk(status),
        "📈 " <> Enum.map_join(Downtime.periods(), " · ", &uptime_line(&1, uptime))
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join("\n")

    {text, instance_buttons(instance)}
  end

  def confirm(%Instance{} = instance, action) do
    {"#{@confirm[action]} <b>#{escape(instance.name)}</b>?",
     [[{"✅ Да", "y:#{action}:#{instance.id}"}, {"✖️ Отмена", "i:" <> instance.id}]]}
  end

  def downtime do
    instances = Instances.list_instances()

    blocks =
      Enum.map(instances, fn instance ->
        uptime = Downtime.summary(instance)

        current =
          case Downtime.open_incident(instance.id) do
            nil ->
              nil

            incident ->
              "🔴 Сейчас простой #{Downtime.format_duration(Downtime.duration(incident))}"
          end

        [
          "<b>#{escape(instance.name)}</b>",
          Enum.map_join(Downtime.periods(), "\n", &uptime_line(&1, uptime, true)),
          current
        ]
        |> Enum.reject(&is_nil/1)
        |> Enum.join("\n")
      end)

    text =
      case blocks do
        [] -> "Пока ни один агент не подключился."
        blocks -> Enum.join(["<b>Простой</b>" | blocks], "\n\n")
      end

    {text, [[{"⬅️ Меню", "m"}, {"🔄 Обновить", "d"}]]}
  end

  def incidents(%Instance{} = instance) do
    uptime = Downtime.summary(instance)

    incidents =
      instance.id
      |> Downtime.list_incidents(10)
      |> Enum.map(fn incident ->
        state = if incident.ended_at, do: "", else: " (идёт)"

        "• #{datetime(incident.started_at)}, " <>
          "#{Downtime.format_duration(Downtime.duration(incident))}#{state}" <>
          problems(incident.problems)
      end)

    text =
      [
        "📉 <b>#{escape(instance.name)}</b>",
        Enum.map_join(Downtime.periods(), "\n", &uptime_line(&1, uptime, true)),
        if(incidents == [],
          do: "Простоев не было",
          else: Enum.join(["<b>Последние простои</b>" | incidents], "\n")
        )
      ]
      |> Enum.join("\n\n")

    {text, [[{"⬅️ Назад", "i:" <> instance.id}, {"🔄 Обновить", "di:" <> instance.id}]]}
  end

  def command_result(%Instance{} = instance, command) do
    ok? = command.status == "ok"
    title = "#{escape(instance.name)}: #{Instances.action_label(command.action)}"
    by = if command.requested_by, do: " (#{escape(command.requested_by)})", else: ""

    cond do
      command.action == "logs" and ok? ->
        "📜 <b>#{title}</b>\n" <> pre(command.output, 3500)

      ok? ->
        "✅ <b>#{title}</b> — готово#{by}"

      true ->
        "❌ <b>#{title}</b> — ошибка#{by}\n" <> pre(command.output, 1500)
    end
  end

  def emoji(level), do: @levels |> Map.fetch!(level) |> elem(0)
  def label(level), do: @levels |> Map.fetch!(level) |> elem(1)

  defp instance_buttons(%Instance{online: false} = instance) do
    [
      [{"📉 Простой", "di:" <> instance.id}],
      [{"⬅️ Сети", "l"}, {"🔄 Обновить", "i:" <> instance.id}]
    ]
  end

  defp instance_buttons(%Instance{id: id}) do
    [
      [{"🔄 Обновить сайт", "a:update:" <> id}, {"♻️ Перезапустить", "a:restart:" <> id}],
      [{"▶️ Включить", "a:start:" <> id}, {"⏸ Выключить", "a:stop:" <> id}],
      [{"📜 Логи", "a:logs:" <> id}, {"📉 Простой", "di:" <> id}],
      [{"⬅️ Сети", "l"}, {"🔄 Обновить", "i:" <> id}]
    ]
  end

  defp hosts(%Instance{hosts: hosts}) when map_size(hosts) > 0,
    do: hosts |> Enum.sort() |> Enum.map_join(" · ", fn {kind, host} -> "#{kind}: #{host}" end)

  defp hosts(_instance), do: nil

  defp container(%{"service" => service, "state" => state} = container) do
    icon = if state == "running", do: "✅", else: "❌"
    revision = if container["revision"], do: " #{String.slice(container["revision"], 0, 7)}"
    "#{icon} #{escape(service)} — #{escape(container["status"] || state)}#{revision}"
  end

  defp container(%{"error" => error}), do: "❌ " <> escape(error)
  defp container(_container), do: nil

  defp checks(instance) do
    internal = (instance.status || %{})["checks"] || %{}

    for kind <- ["api", "site"], internal[kind] || instance.external[kind] do
      "#{if kind == "api", do: "API", else: "Сайт"}: " <>
        "изнутри #{check(internal[kind])}, снаружи #{check(instance.external[kind])}"
    end
  end

  defp check(nil), do: "—"
  defp check(%{"ok" => true} = check), do: "#{check["status"]} · #{check["ms"]} мс"
  defp check(check), do: "❌ " <> escape(to_string(check["status"] || check["error"]))

  defp disk(%{"disk" => %{"used_kb" => used, "total_kb" => total}}) when total > 0,
    do: "Диск: #{round(used / total * 100)}% занято"

  defp disk(_status), do: nil

  defp uptime_line(period, uptime, downtime? \\ false) do
    %{uptime: percent, down_seconds: down} = uptime[period]
    line = "#{Downtime.format_period(period)}: #{format_uptime(percent)}"

    if downtime? and down > 0,
      do: "#{line}, простой #{Downtime.format_duration(down)}",
      else: line
  end

  defp format_uptime(percent) when percent >= 100, do: "100%"
  defp format_uptime(percent), do: :erlang.float_to_binary(percent, decimals: 2) <> "%"

  defp problems([]), do: ""
  defp problems(problems), do: "\n  " <> escape(Enum.join(problems, "; "))

  defp section(_title, []), do: nil

  defp section(title, lines),
    do: Enum.join(["\n<b>#{title}</b>" | Enum.reject(lines, &is_nil/1)], "\n")

  defp pre(nil, _limit), do: ""

  defp pre(output, limit) do
    output = String.trim(output)

    output =
      if String.length(output) > limit,
        do: "…" <> String.slice(output, -limit, limit),
        else: output

    "<pre>#{escape(output)}</pre>"
  end

  defp ago(nil), do: "никогда"

  defp ago(at) do
    "#{Downtime.format_duration(DateTime.diff(DateTime.utc_now(), at))} назад"
  end

  defp datetime(at), do: Calendar.strftime(at, "%d.%m %H:%M UTC")
end
