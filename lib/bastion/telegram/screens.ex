defmodule Bastion.Telegram.Screens do
  @moduledoc "Texts and inline keyboards of the bot, in Telegram HTML."

  import Bastion.Telegram, only: [escape: 1]

  alias Bastion.{Alerts, Backups, Downtime, Health, Images, Instances, Telegram, Updates}
  alias Bastion.Instances.Instance

  @levels %{
    ok: {"🟢", "работает"},
    warning: {"🟡", "есть предупреждения"},
    down: {"🔴", "ошибки"},
    offline: {"⚫", "агент не на связи"},
    stopped: {"⏸", "выключен по плану"},
    unknown: {"❔", "нет данных"}
  }

  @order [:down, :offline, :warning, :unknown, :stopped, :ok]

  @confirm %{
    "rollback" => "Вернуть образы, которые работали до обновления",
    "restart" => "Перезапустить",
    "stop" => "Выключить"
  }

  def confirm?(action), do: action == "update" or Map.has_key?(@confirm, action)

  @doc "Sites with problems first, each with its first problem; the working ones in one line."
  def instances(instances \\ Instances.list_instances(), title \\ "Сети") do
    rated =
      instances
      |> Enum.map(&{&1, Health.evaluate(&1)})
      |> Enum.sort_by(fn {instance, health} ->
        {Enum.find_index(@order, &(&1 == health.level)), instance.name}
      end)

    {working, others} = Enum.split_with(rated, fn {_instance, health} -> health.level == :ok end)

    lines =
      Enum.map(others, fn {instance, health} ->
        "#{emoji(health.level)} <b>#{escape(instance.name)}</b> — " <>
          escape(List.first(health.problems) || label(health.level))
      end)

    summary =
      cond do
        working == [] -> nil
        others == [] -> "🟢 Все работают"
        true -> "🟢 Остальные работают: #{length(working)}"
      end

    text =
      case rated do
        [] ->
          "Пока ни один агент не подключился."

        _ ->
          ["<b>#{title}</b> · #{length(rated)}", Enum.join(lines, "\n"), summary]
          |> Enum.reject(&(&1 in [nil, ""]))
          |> Enum.join("\n")
      end

    buttons =
      rated
      |> Enum.map(fn {instance, health} ->
        {"#{emoji(health.level)} #{instance.name}", "i:" <> instance.id}
      end)
      |> Enum.chunk_every(2)

    {text, buttons ++ [[{"🔄 Обновить", "l"}]]}
  end

  def not_found(query) do
    {text, buttons} = instances()
    {"Не нашёл «#{escape(query)}».\n\n" <> text, buttons}
  end

  @doc "The short card of a site; `notice` is the result of a command sent from it."
  def instance(%Instance{} = instance, notice \\ nil) do
    health = Health.evaluate(instance)
    running = Instances.running_command(instance.id)
    outdated = if instance.online, do: Images.outdated(instance), else: []

    text =
      [
        "#{emoji(health.level)} <b>#{escape(instance.name)}</b> — #{label(health.level)}",
        notice,
        running && "⏳ #{Instances.action_label(running.action)}…",
        Alerts.muted?(instance) && "🔕 Без уведомлений до #{time(instance.muted_until)}",
        problems(health.problems),
        outdated != [] && "⬆️ Есть новая версия: #{escape(Enum.join(outdated, ", "))}",
        facts(instance, health)
      ]
      |> Enum.reject(&(&1 in [nil, false, ""]))
      |> Enum.join("\n")

    {text, instance_buttons(instance, running, outdated)}
  end

  @doc "Actions that are needed rarely."
  def more(%Instance{id: id} = instance) do
    power =
      if instance.stopped_at,
        do: {"▶️ Включить", "a:start:" <> id},
        else: {"⏸ Выключить", "a:stop:" <> id}

    backup = if Backups.supported?(instance), do: [{"💾 Бэкап", "a:backup:" <> id}], else: []

    {"<b>#{escape(instance.name)}</b> · ещё",
     [
       [{"⬆️ Обновить", "a:update:" <> id}, {"♻️ Перезапустить", "a:restart:" <> id}],
       [power | backup],
       [mute_button(instance)],
       [{"⬅️ Назад", "i:" <> id}]
     ]}
  end

  @doc "Everything the card leaves out: hosts, containers, checks, uptime and incidents."
  def details(%Instance{} = instance) do
    status = instance.status || %{}
    uptime = Downtime.summary(instance)

    incidents =
      instance.id
      |> Downtime.list_incidents(5)
      |> Enum.map(fn incident ->
        state = if incident.ended_at, do: "", else: " (идёт)"

        "• #{datetime(incident.started_at)}, " <>
          "#{Downtime.format_duration(Downtime.duration(incident))}#{state}" <>
          incident_problems(incident.problems)
      end)

    text =
      [
        "<b>#{escape(instance.name)}</b> · подробно",
        hosts(instance),
        "Агент #{escape(instance.agent_version || "—")}, " <>
          "#{if instance.online, do: "на связи", else: "не на связи"}, #{ago(instance.last_seen_at)}",
        instance.stopped_at && "⏸ Выключен по плану #{datetime(instance.stopped_at)}",
        section("Контейнеры", Enum.map(List.wrap(status["containers"]), &container/1)),
        section("Проверки", checks(instance)),
        section("Аптайм", Enum.map(Downtime.periods(), &uptime_line(&1, uptime))),
        section("Последние простои", incidents)
      ]
      |> Enum.reject(&(&1 in [nil, false]))
      |> Enum.join("\n")

    {text, [[{"⬅️ Назад", "i:" <> instance.id}, {"🔄 Обновить", "x:" <> instance.id}]]}
  end

  def confirm(%Instance{} = instance, action) do
    {"#{confirm_text(instance, action)} <b>#{escape(instance.name)}</b>?",
     [[{"✅ Да", "y:#{action}:#{instance.id}"}, {"✖️ Отмена", "i:" <> instance.id}]]}
  end

  defp confirm_text(instance, "update") do
    if Updates.backup_first?(instance),
      do: "Сделать бэкап, скачать новые образы и перезапустить",
      else: "Скачать новые образы и перезапустить"
  end

  defp confirm_text(_instance, action), do: @confirm[action]

  def notice(%{status: "ok", action: action}), do: "✅ #{Instances.action_label(action)} — готово"
  def notice(%{action: action}), do: "❌ #{Instances.action_label(action)} — ошибка"

  def command_result(%Instance{} = instance, command) do
    title = "#{escape(instance.name)}: #{Instances.action_label(command.action)}"

    by =
      if command.requested_by && not Telegram.private_chat?(),
        do: " (#{escape(command.requested_by)})",
        else: ""

    if command.status == "ok",
      do: "✅ <b>#{title}</b> — готово#{by}",
      else: "❌ <b>#{title}</b> — ошибка#{by}\n" <> pre(command.output, 1500)
  end

  def error_output(command), do: "❌ <b>Вывод</b>\n" <> pre(command.output, 3500)

  def logs_file(%Instance{} = instance) do
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y%m%d-%H%M")
    slug = instance.name |> String.downcase() |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
    "#{String.trim(slug, "-")}-logs-#{stamp}.txt"
  end

  def emoji(level), do: @levels |> Map.fetch!(level) |> elem(0)
  def label(level), do: @levels |> Map.fetch!(level) |> elem(1)

  defp instance_buttons(%Instance{id: id} = instance, running, outdated) do
    main =
      cond do
        not instance.online or running -> []
        instance.stopped_at -> [{"▶️ Включить", "a:start:" <> id}]
        outdated != [] -> [{"⬆️ Обновить", "a:update:" <> id}]
        true -> []
      end

    main =
      if rollback?(instance) and not running,
        do: main ++ [{"⏪ Откатить", "a:rollback:" <> id}],
        else: main

    actions =
      cond do
        not instance.online -> [{"ℹ️ Подробнее", "x:" <> id}, mute_button(instance)]
        running -> [{"ℹ️ Подробнее", "x:" <> id}]
        true -> [{"📜 Логи", "a:logs:" <> id}, {"ℹ️ Подробнее", "x:" <> id}, {"⋯ Ещё", "e:" <> id}]
      end

    [main, actions, links(instance), [{"⬅️ Сети", "l"}, {"🔄 Обновить", "i:" <> id}]]
    |> Enum.reject(&(&1 == []))
  end

  defp rollback?(instance),
    do:
      instance.online and "rollback" in instance.actions and
        is_map((instance.status || %{})["rollback"])

  defp mute_button(instance) do
    if Alerts.muted?(instance),
      do: {"🔔 Включить уведомления", "cm:" <> instance.id},
      else: {"🔕 Тихо 1 ч", "cm:" <> instance.id}
  end

  @doc "Buttons to the client site and the staff admin of the site."
  def links(%Instance{hosts: hosts}) do
    [
      link("🌐 Сайт", hosts["site"], ""),
      link("🛠 Админка", hosts["api"], "/staff/dashboard")
    ]
    |> Enum.filter(& &1)
  end

  defp link(label, host, path) when is_binary(host) do
    url = "https://#{host}#{path}"
    if public_url?(url), do: {label, {:url, url}}
  end

  defp link(_label, _host, _path), do: nil

  defp public_url?(url) do
    case URI.new(url) do
      {:ok, %URI{host: host}} when is_binary(host) -> String.contains?(host, ".")
      _ -> false
    end
  end

  defp facts(instance, health) do
    uptime = Downtime.summary(instance)

    [
      health.level == :offline && "был на связи #{ago(instance.last_seen_at)}",
      disk(instance.status || %{}),
      last_backup(instance),
      "аптайм 30 дн #{format_uptime(uptime[:month].uptime)}"
    ]
    |> Enum.filter(& &1)
    |> Enum.join(" · ")
  end

  defp last_backup(instance) do
    if Backups.supported?(instance) do
      case Enum.find(Backups.list(instance.id), &(&1.status == "ok")) do
        nil -> "бэкапов нет"
        backup -> "бэкап #{ago(backup.inserted_at)}"
      end
    end
  end

  defp problems([]), do: nil

  defp problems(problems),
    do: "\n" <> Enum.map_join(problems, "\n", &("• " <> escape(&1))) <> "\n"

  defp hosts(%Instance{hosts: hosts}) when map_size(hosts) > 0 do
    hosts
    |> Enum.sort()
    |> Enum.map_join(" · ", fn {kind, host} ->
      ~s(#{kind}: <a href="https://#{escape(host)}">#{escape(host)}</a>)
    end)
  end

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
    do: "диск #{round(used / total * 100)}%"

  defp disk(_status), do: nil

  defp uptime_line(period, uptime) do
    %{uptime: percent, down_seconds: down} = uptime[period]
    line = "#{Downtime.format_period(period)}: #{format_uptime(percent)}"
    if down > 0, do: "#{line}, простой #{Downtime.format_duration(down)}", else: line
  end

  defp format_uptime(percent) when percent >= 100, do: "100%"
  defp format_uptime(percent), do: :erlang.float_to_binary(percent, decimals: 2) <> "%"

  defp incident_problems([]), do: ""
  defp incident_problems(problems), do: "\n  " <> escape(Enum.join(problems, "; "))

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

  defp time(at), do: Calendar.strftime(at, "%H:%M UTC")
  defp datetime(at), do: Calendar.strftime(at, "%d.%m %H:%M UTC")
end
