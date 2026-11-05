defmodule BastionWeb.InstanceLive.Show do
  use BastionWeb, :live_view

  import BastionWeb.InstanceLive.Components
  import BastionWeb.InstanceLive.LoadChart

  alias Bastion.{
    Backups,
    CrmAlerts,
    Downtime,
    Health,
    Images,
    Instances,
    Maintenance,
    Metrics,
    SiteAlerts
  }

  alias BastionWeb.InstanceLive.Links
  alias BastionWeb.Presence

  @tick :timer.seconds(15)
  @tabs [
    {"state", "Обзор"},
    {"errors", "Ошибки"},
    {"logs", "Логи"},
    {"backups", "Бэкапы"},
    {"history", "История"},
    {"settings", "Настройки"}
  ]
  @max_dump_size 5 * 1024 * 1024 * 1024

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Instances.get_instance(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Экземпляр не найден") |> push_navigate(to: ~p"/")}

      instance ->
        if connected?(socket) do
          Instances.subscribe()
          Phoenix.PubSub.subscribe(Bastion.PubSub, Presence.topic())
          :timer.send_interval(@tick, :tick)
        end

        {:ok,
         socket
         |> assign(
           page_title: instance.name,
           logs_form: to_form(%{"service" => "", "tail" => "200"}),
           env_form: to_form(%{"content" => ""}),
           env_request: nil,
           env_loaded?: false,
           maintenance_form: to_form(%{"minutes" => "30"}),
           maintenance_open?: false,
           metrics_period: :day,
           tab: "state"
         )
         |> allow_upload(:dump, accept: :any, max_entries: 1, max_file_size: @max_dump_size)
         |> assign_instance(instance)
         |> load_commands()
         |> load_backups()
         |> load_metrics()}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if Enum.any?(@tabs, &(elem(&1, 0) == params["tab"])), do: params["tab"], else: "state"
    {:noreply, assign(socket, tab: tab)}
  end

  @impl true
  def handle_event("command", %{"action" => "update"}, socket) do
    socket =
      case Bastion.Updates.update(socket.assigns.instance, socket.assigns.current_admin) do
        {:ok, command} -> show_logs(socket, command)
        {:error, :offline} -> put_flash(socket, :error, "Агент не на связи")
        {:error, :unknown_action} -> put_flash(socket, :error, "Неизвестная команда")
      end

    {:noreply, socket}
  end

  def handle_event("command", %{"action" => action}, socket) do
    {:noreply, send_command(socket, action, %{}, &show_logs/2)}
  end

  def handle_event("logs", %{"service" => service, "tail" => tail}, socket) do
    socket = assign(socket, logs_form: to_form(%{"service" => service, "tail" => tail}))
    {:noreply, send_command(socket, "logs", %{"service" => service, "tail" => tail})}
  end

  def handle_event("crm_dismiss", %{"id" => order_id}, socket) do
    case CrmAlerts.dismiss(socket.assigns.instance, order_id) do
      {:ok, instance} ->
        {:noreply, assign_instance(socket, instance)}

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Не удалось убрать оповещение")}
    end
  end

  def handle_event("validate_dump", _params, socket), do: {:noreply, socket}

  def handle_event("restore_file", _params, socket) do
    %{instance: instance, current_admin: admin} = socket.assigns

    results =
      consume_uploaded_entries(socket, :dump, fn %{path: path}, entry ->
        {:ok, Backups.import_file(instance, path, "#{admin} · #{entry.client_name}")}
      end)

    socket =
      case results do
        [{:ok, backup}] -> restore_backup(socket, backup)
        [{:error, reason}] -> put_flash(socket, :error, "Файл не принят: #{reason}")
        [] -> put_flash(socket, :error, "Выберите файл дампа")
      end

    {:noreply, load_backups(socket)}
  end

  def handle_event("env_load", _params, socket) do
    {:noreply, send_command(socket, "env_read", %{}, &assign(&1, env_request: &2.id))}
  end

  def handle_event("env_change", %{"content" => content}, socket),
    do: {:noreply, assign(socket, env_form: to_form(%{"content" => content}))}

  def handle_event("env_save", %{"content" => content}, socket) do
    socket = assign(socket, env_form: to_form(%{"content" => content}))

    {:noreply,
     send_command(socket, "env_write", %{"content" => content}, fn socket, _command ->
       put_flash(socket, :info, ".env отправлен агенту, сервисы будут пересозданы")
     end)}
  end

  def handle_event("metrics_period", %{"period" => period}, socket) do
    period = Enum.find(Metrics.periods(), :day, &(to_string(&1) == period))
    {:noreply, socket |> assign(metrics_period: period) |> load_metrics()}
  end

  def handle_event("backup", _params, socket) do
    socket =
      case Backups.start(socket.assigns.instance, socket.assigns.current_admin) do
        {:ok, _backup} -> put_flash(socket, :info, "Агент делает бэкап")
        {:error, reason} -> put_flash(socket, :error, "Бэкап не начат: #{reason}")
      end

    {:noreply, load_backups(socket)}
  end

  def handle_event("maintenance_toggle", _params, socket),
    do: {:noreply, assign(socket, maintenance_open?: !socket.assigns.maintenance_open?)}

  def handle_event("maintenance_start", %{"minutes" => value}, socket) do
    minutes =
      case Integer.parse(value) do
        {number, ""} -> number
        _ -> nil
      end

    socket =
      case Maintenance.start(socket.assigns.instance, minutes) do
        {:ok, instance} ->
          socket
          |> assign_instance(instance)
          |> assign(maintenance_open?: false)
          |> put_flash(:info, "Обслуживание включено")

        {:error, _reason} ->
          put_flash(socket, :error, "Не удалось включить обслуживание")
      end

    {:noreply, socket}
  end

  def handle_event("maintenance_finish", _params, socket) do
    socket =
      case Maintenance.finish(socket.assigns.instance) do
        {:ok, instance} ->
          socket |> assign_instance(instance) |> put_flash(:info, "Обслуживание завершено")

        {:error, _reason} ->
          put_flash(socket, :error, "Не удалось завершить обслуживание")
      end

    {:noreply, socket}
  end

  def handle_event("restore", %{"backup_id" => backup_id}, socket) do
    socket =
      case Backups.get(backup_id) do
        %{status: "ok", instance_id: id} = backup when id == socket.assigns.instance.id ->
          restore_backup(socket, backup)

        _ ->
          put_flash(socket, :error, "Бэкап не найден")
      end

    {:noreply, socket}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Instances.delete_instance(socket.assigns.instance)
    {:noreply, socket |> put_flash(:info, "Экземпляр удалён") |> push_navigate(to: ~p"/")}
  end

  @impl true
  def handle_info({:instance_updated, %{id: id}}, %{assigns: %{instance: %{id: id}}} = socket),
    do: {:noreply, reload(socket)}

  def handle_info({:instance_deleted, %{id: id}}, %{assigns: %{instance: %{id: id}}} = socket),
    do: {:noreply, push_navigate(socket, to: ~p"/")}

  def handle_info(
        {:command_updated, %{instance_id: id} = command},
        %{assigns: %{instance: %{id: id}}} = socket
      ) do
    socket =
      if command.id == socket.assigns.env_request and command.status == "error",
        do: assign(socket, env_request: nil),
        else: socket

    {:noreply, load_commands(socket)}
  end

  def handle_info({:backup_updated, _backup}, socket), do: {:noreply, load_backups(socket)}

  def handle_info({:env_loaded, %{id: id}, content}, %{assigns: %{env_request: id}} = socket) do
    {:noreply,
     assign(socket,
       env_form: to_form(%{"content" => content}),
       env_request: nil,
       env_loaded?: true
     )}
  end

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, reload(socket)}

  def handle_info(:tick, socket), do: {:noreply, socket |> reload() |> load_metrics()}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp restore_backup(socket, backup) do
    case Backups.restore(socket.assigns.instance, backup, socket.assigns.current_admin) do
      {:ok, _command} ->
        socket
        |> put_flash(:info, "Агент восстанавливает базу из бэкапа")
        |> show_logs(nil)

      {:error, :offline} ->
        put_flash(socket, :error, "Агент не на связи")

      {:error, :unsupported} ->
        put_flash(socket, :error, "Агент не умеет восстанавливать, обновите экземпляр")
    end
  end

  defp show_logs(socket, _command),
    do: push_patch(socket, to: ~p"/instances/#{socket.assigns.instance.id}?tab=logs")

  defp send_command(socket, action, args, on_sent \\ fn socket, _command -> socket end) do
    case Instances.send_command(
           socket.assigns.instance,
           action,
           args,
           socket.assigns.current_admin
         ) do
      {:ok, command} -> on_sent.(socket, command)
      {:error, :offline} -> put_flash(socket, :error, "Агент не на связи")
      {:error, :unknown_action} -> put_flash(socket, :error, "Неизвестная команда")
    end
  end

  defp reload(socket) do
    case Instances.get_instance(socket.assigns.instance.id) do
      nil -> push_navigate(socket, to: ~p"/")
      instance -> assign_instance(socket, instance)
    end
  end

  defp assign_instance(socket, instance) do
    assign(socket,
      instance: instance,
      health: Health.evaluate(instance),
      uptime: Downtime.summary(instance),
      incidents: Downtime.list_incidents(instance.id),
      operations: Instances.last_successful_operations(instance.id),
      maintenance_windows: Maintenance.windows(instance)
    )
  end

  defp load_backups(socket) do
    id = socket.assigns.instance.id

    assign(socket, backups: Backups.list(id))
  end

  defp load_metrics(socket) do
    id = socket.assigns.instance.id

    assign(socket,
      load: Metrics.latest(id),
      load_series: Metrics.series(id, socket.assigns.metrics_period)
    )
  end

  defp since_label(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, at, _offset} -> datetime(at)
      _ -> iso
    end
  end

  defp since_label(_), do: nil

  defp gigabytes(kb), do: :erlang.float_to_binary(kb / 1_048_576, decimals: 1) <> " ГБ"

  defp backups_supported?(instance), do: Backups.supported?(instance)

  defp format_size(nil), do: "—"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{max(div(bytes, 1024), 1)} КБ"
  defp format_size(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " МБ"

  defp load_commands(socket),
    do: assign(socket, commands: Instances.list_commands(socket.assigns.instance.id))

  defp containers(%{status: %{"containers" => containers}}), do: containers
  defp containers(_instance), do: []

  defp start_needed?(%{stopped_at: stopped_at} = instance) do
    not is_nil(stopped_at) or
      Enum.any?(containers(instance), fn container ->
        container["service"] in ["server", "client"] and container["state"] != "running"
      end)
  end

  defp services(instance),
    do: instance |> containers() |> Enum.map(& &1["service"]) |> Enum.filter(&is_binary/1)

  defp env_supported?(instance), do: "env_write" in instance.actions

  defp rollback(%{actions: actions, status: %{"rollback" => %{} = rollback}}) do
    if "rollback" in actions, do: rollback
  end

  defp rollback(_instance), do: nil

  defp agent_revision(%{status: %{"agent" => %{"version" => version}}}) when is_binary(version),
    do: version

  defp agent_revision(%{status: %{"agent" => %{"revision" => revision}}})
       when is_binary(revision),
       do: String.slice(revision, 0, 7)

  defp agent_revision(_instance), do: "—"

  defp app_stats?(%{status: %{} = status}),
    do: is_map(status["orders"]) or is_map(status["errors"]) or is_map(status["database"])

  defp app_stats?(_instance), do: false

  defp latest_errors(%{status: %{"errors" => %{"latest" => latest}}}) when is_list(latest),
    do: latest

  defp latest_errors(_instance), do: []

  defp database_size(%{status: %{"database" => %{"size_bytes" => bytes}}}) when is_integer(bytes),
    do: format_size(bytes)

  defp database_size(_instance), do: "—"

  defp free_disk(%{status: %{"disk" => %{"free_kb" => free}}}) when is_integer(free),
    do: gigabytes(free)

  defp free_disk(_instance), do: "—"

  defp missing_env(%{status: %{"env" => %{"missing" => missing}}}) when is_list(missing),
    do: missing

  defp missing_env(_instance), do: []

  # app_logs keeps UTC without an offset.
  defp error_time(at) when is_binary(at) do
    case NaiveDateTime.from_iso8601(at) do
      {:ok, at} ->
        at |> DateTime.from_naive!("Etc/UTC") |> DateTime.truncate(:second) |> datetime()

      _ ->
        at
    end
  end

  defp error_time(_at), do: ""

  defp site_alert_icon("orders"), do: "hero-shopping-cart"
  defp site_alert_icon("errors"), do: "hero-bug-ant"
  defp site_alert_icon("disk"), do: "hero-circle-stack"
  defp site_alert_icon(_key), do: "hero-exclamation-triangle"

  defp rollback_confirmation(rollback) do
    at = since_label(rollback["at"])
    when_updated = if at, do: " #{at}", else: ""

    "Вернуть образы и код, которые работали до обновления#{when_updated}? База останется как есть."
  end

  defp busy?(commands), do: Enum.any?(commands, &(&1.status in ["sent", "running"]))

  defp tabs, do: @tabs

  defp errors_count(instance, health),
    do:
      length(CrmAlerts.problems(instance)) + length(health.problems) +
        map_size(instance.load_alerts) + map_size(instance.site_alerts)

  defp upload_error(:too_large), do: "файл больше 5 ГБ"
  defp upload_error(:too_many_files), do: "можно только один файл"
  defp upload_error(error), do: to_string(error)

  defp operation_time(nil), do: nil

  defp operation_time(command),
    do: command.finished_at || command.started_at || command.inserted_at

  defp operation_label(nil), do: "Нет записей в Bastion"
  defp operation_label(command), do: datetime(operation_time(command))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <.link
        navigate={~p"/"}
        class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Все франшизы
      </.link>

      <div class="flex flex-wrap items-start justify-between gap-5">
        <div class="space-y-1">
          <div class="flex items-center gap-3">
            <h1 class="text-2xl font-bold">{@instance.name}</h1>
            <.health_badge level={@health.level} />
          </div>
          <div class="text-xs text-base-content/60">
            Последний контакт: {ago(@instance.last_seen_at)}
          </div>
        </div>

        <div id="instance-actions" class="flex flex-wrap items-center gap-2">
          <button
            id="instance-update"
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="command"
            phx-value-action="update"
            disabled={!@instance.online || busy?(@commands)}
            data-confirm="Скачать новые образы и перезапустить сайт?"
          >
            <.icon name="hero-arrow-path" class="size-4" /> Обновить
          </button>
          <button
            id="instance-backup"
            type="button"
            class="btn btn-sm"
            phx-click="backup"
            disabled={!@instance.online || busy?(@commands) || !backups_supported?(@instance)}
          >
            <.icon name="hero-circle-stack" class="size-4" /> Сделать бэкап
          </button>
          <button
            :if={!Maintenance.active?(@instance)}
            id="maintenance-open"
            type="button"
            class="btn btn-sm"
            phx-click="maintenance_toggle"
            aria-expanded={@maintenance_open?}
            aria-controls="maintenance-form"
          >Обслуживание</button>
          <.form
            :if={@maintenance_open? && !Maintenance.active?(@instance)}
            for={@maintenance_form}
            id="maintenance-form"
            phx-submit="maintenance_start"
            class="flex flex-wrap items-center gap-2"
            data-confirm="Включить режим обслуживания? Простои в это время не будут учитываться, но сервис продолжит работать."
          >
            <p class="w-full text-xs text-base-content/60">
              Сайты продолжат работать. Плановый период исключается из расчёта доступности и завершится автоматически.
            </p>
            <.input
              field={@maintenance_form[:minutes]}
              type="select"
              label="Длительность обслуживания"
              options={[
                {"15 минут", "15"},
                {"30 минут", "30"},
                {"60 минут", "60"},
                {"120 минут", "120"}
              ]}
              class="select select-sm"
            />
            <button id="maintenance-start" type="submit" class="btn btn-sm">Включить на выбранное время</button>
          </.form>
          <button
            :if={start_needed?(@instance)}
            id="instance-start"
            type="button"
            class="btn btn-sm"
            phx-click="command"
            phx-value-action="start"
            disabled={!@instance.online || busy?(@commands)}
          >
            Включить
          </button>
        </div>
      </div>

      <div
        :if={Maintenance.active?(@instance)}
        id="maintenance-active"
        class="rounded-xl border border-sky-300 bg-sky-50 p-4 text-sm text-sky-950 flex flex-wrap items-center justify-between gap-3"
      >
        <span>Обслуживание до {datetime(@instance.maintenance_until)}. Сервис продолжает работать, простои не учитываются.</span>
        <button
          id="maintenance-finish"
          type="button"
          class="btn btn-sm"
          phx-click="maintenance_finish"
          data-confirm="Завершить обслуживание сейчас?"
        >Завершить обслуживание</button>
      </div>

      <div :if={@instance.stopped_at} id="instance-stopped" class="alert alert-info">
        <.icon name="hero-pause-circle" class="size-5" />
        <span>
          Сайт выключен по плану {datetime(@instance.stopped_at)}. Пока его не включат,
          недоступность не считается ошибкой и уведомления не приходят.
        </span>
      </div>

      <div id="instance-endpoints" class="grid gap-4 md:grid-cols-2">
        <section
          :for={kind <- ["api", "site"]}
          id={if(kind == "api", do: "server-card", else: "client-card")}
          class="rounded-xl border border-base-300 bg-base-100 p-5 shadow-sm"
        >
          <div class="flex flex-wrap items-start justify-between gap-3">
            <div>
              <h2 class="text-lg font-semibold">{if kind == "api", do: "Server", else: "Client"}</h2>
              <p class="text-xs text-base-content/60">
                {if kind == "api", do: "Админка", else: "Приложение"}
              </p>
              <p class="text-sm text-base-content/60 break-all">
                {Links.display(@instance.hosts[kind])}
              </p>
            </div>
            <.open_link
              id={if(kind == "api", do: "detail-server-open", else: "detail-client-open")}
              host={@instance.hosts[kind]}
              kind={if(kind == "api", do: "server", else: "client")}
              instance_name={@instance.name}
            />
          </div>
          <div class="mt-4 grid gap-2 text-sm sm:grid-cols-2">
            <div>
              <span class="text-base-content/60">Доступность снаружи</span><div>
                <.check check={@instance.external[kind]} />
              </div>
            </div>
            <div>
              <span class="text-base-content/60">Сертификат</span><div>
                <% days = cert_days((@instance.external[kind] || %{})["cert_expires_at"]) %>
                <span :if={days}>{days} дн. до окончания</span><span
                  :if={!days}
                  class="text-base-content/50"
                >Нет данных</span>
              </div>
            </div>
          </div>
        </section>
      </div>

      <div id="recent-operations" class="grid gap-2 text-xs sm:grid-cols-2">
        <div class="rounded-lg border border-base-300 bg-base-100 px-3 py-2">
          <div class="text-base-content/60">Последнее обновление через Bastion</div>
          <div class="mt-0.5 font-medium">{operation_label(@operations.update)}</div>
        </div>
        <div class="rounded-lg border border-base-300 bg-base-100 px-3 py-2">
          <div class="text-base-content/60">Последнее восстановление бэкапа через Bastion</div>
          <div class="mt-0.5 font-medium">{operation_label(@operations.restore)}</div>
        </div>
      </div>

      <div role="tablist" id="instance-tabs" class="tabs tabs-box w-fit flex-wrap">
        <.link
          :for={{tab, label} <- tabs()}
          patch={~p"/instances/#{@instance.id}?tab=#{tab}"}
          role="tab"
          id={"tab-#{tab}"}
          class={["tab gap-2", @tab == tab && "tab-active"]}
        >
          {label}
        </.link>
      </div>

      <div :if={@tab == "state"} id="tab-state-panel" class="space-y-4">
        <section id="uptime" class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-3">
            <h2 class="font-bold">Доступность</h2>
            <div class="grid grid-cols-3 gap-2">
              <div :for={period <- Downtime.periods()} class="rounded-box bg-base-200 p-3">
                <div class="text-xs text-base-content/60">{Downtime.format_period(period)}</div>
                <div class={["text-xl font-bold tabular-nums", uptime_class(@uptime[period].uptime)]}>
                  {format_uptime(@uptime[period].uptime)}
                </div>
                <div class="text-xs text-base-content/60">
                  простой {Downtime.format_duration(@uptime[period].down_seconds)}
                </div>
              </div>
            </div>
          </div>
        </section>
        <section
          :if={app_stats?(@instance)}
          id="app-stats"
          class="card bg-base-100 border border-base-300"
        >
          <div class="card-body p-4 gap-3">
            <h2 class="font-bold">Приложение</h2>
            <div class="grid gap-2 sm:grid-cols-2">
              <div class="rounded-box bg-base-200 p-3">
                <div class="text-xs text-base-content/60">Заказы за час</div>
                <div class="text-xl font-bold tabular-nums">
                  {get_in(@instance.status, ["orders", "last_hour"]) || "—"}
                </div>
                <div class="text-xs text-base-content/60">
                  обычно {get_in(@instance.status, ["orders", "usual"]) || "—"}
                </div>
              </div>
              <div class="rounded-box bg-base-200 p-3">
                <div class="text-xs text-base-content/60">База данных</div>
                <div class="text-xl font-bold tabular-nums">
                  {database_size(@instance)}
                </div>
                <div class="text-xs text-base-content/60">
                  свободно на диске {free_disk(@instance)}
                </div>
              </div>
            </div>
          </div>
        </section>

        <section id="load" class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-4">
            <div class="flex flex-wrap items-center justify-between gap-2">
              <div>
                <h2 class="font-bold">Физический сервер</h2>
                <p class="text-xs text-base-content/60">
                  CPU и RAM всего хоста, включая остальные сервисы
                </p>
              </div>
              <div role="tablist" class="join">
                <button
                  :for={period <- Metrics.periods()}
                  type="button"
                  role="tab"
                  phx-click="metrics_period"
                  phx-value-period={period}
                  class={["btn btn-xs join-item", @metrics_period == period && "btn-active"]}
                >
                  {Metrics.period_label(period)}
                </button>
              </div>
            </div>

            <div :if={@load} id="load-now" class="grid grid-cols-3 gap-2">
              <div class="rounded-box bg-base-200 p-3">
                <div class="text-xs text-base-content/60">CPU хоста</div>
                <div class="text-xl font-bold tabular-nums">
                  {(@load.cpu && percent(@load.cpu)) || "—"}
                </div>
                <div :if={@load.cpus} class="text-xs text-base-content/60">{@load.cpus} ядер</div>
              </div>
              <div class="rounded-box bg-base-200 p-3">
                <div class="text-xs text-base-content/60">RAM хоста</div>
                <div class="text-xl font-bold tabular-nums">
                  {(@load.memory && percent(@load.memory)) || "—"}
                </div>
                <div :if={@load.memory_total_kb} class="text-xs text-base-content/60 tabular-nums">
                  {gigabytes(@load.memory_used_kb)} из {gigabytes(@load.memory_total_kb)}
                </div>
              </div>
              <div class="rounded-box bg-base-200 p-3">
                <div class="text-xs text-base-content/60">Load average</div>
                <div class="text-xl font-bold tabular-nums">
                  {(@load.load && :erlang.float_to_binary(@load.load, decimals: 2)) || "—"}
                </div>
                <div class="text-xs text-base-content/60">за минуту</div>
              </div>
            </div>

            <p :if={!@load} class="text-sm text-base-content/60">
              Агент ещё не присылал нагрузку. Если это длится дольше пары минут, обновите агента на сервере.
            </p>

            <div class="grid gap-4 md:grid-cols-2">
              <.load_chart
                id="load-cpu"
                title="Процессор"
                series={@load_series}
                field={:cpu}
                color="text-primary"
              />
              <.load_chart
                id="load-memory"
                title="Память"
                series={@load_series}
                field={:memory}
                color="text-info"
              />
            </div>
          </div>
        </section>

        <details id="technical-details" class="rounded-xl border border-base-300 bg-base-100 p-4">
          <summary class="cursor-pointer font-semibold">Технические подробности</summary>
          <p class="mt-2 mb-4 text-xs text-base-content/60">
            Версия агента: {@instance.agent_version || "—"} · образ {agent_revision(@instance)}
          </p>
          <div class="grid gap-4 md:grid-cols-2">
            <section class="card bg-base-100 border border-base-300">
              <div class="card-body p-4">
                <h2 class="font-bold">Контейнеры</h2>
                <table id="containers" class="table table-sm">
                  <tbody>
                    <tr :for={container <- containers(@instance)}>
                      <td class="font-semibold">{container["service"]}</td>
                      <td class={(container["state"] == "running" && "text-success") || "text-error"}>
                        {container["state"]}
                      </td>
                      <td class="text-xs text-base-content/60">{container["status"]}</td>
                      <td class="font-mono text-xs">
                        {container["version"] || String.slice(container["revision"] || "", 0, 7)}
                      </td>
                      <td
                        class={[
                          "text-xs tabular-nums whitespace-nowrap",
                          (container["restarts"] || 0) > 0 && "text-warning"
                        ]}
                        title="Сколько раз docker перезапускал контейнер после падения"
                      >
                        <span :if={is_integer(container["restarts"])}>
                          ↻ {container["restarts"]}
                        </span>
                      </td>
                    </tr>
                    <tr :if={containers(@instance) == []}>
                      <td class="text-base-content/60">Нет данных</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </section>

            <section class="card bg-base-100 border border-base-300">
              <div class="card-body p-4">
                <h2 class="font-bold">Проверки</h2>
                <table id="checks" class="table table-sm">
                  <thead>
                    <tr>
                      <th></th>
                      <th>Изнутри</th>
                      <th>Снаружи</th>
                      <th>Сертификат</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={kind <- ["api", "site"]}>
                      <td class="font-semibold">{if kind == "api", do: "Server", else: "Client"}</td>
                      <td><.check check={(@instance.status || %{})["checks"][kind]} /></td>
                      <td><.check check={@instance.external[kind]} /></td>
                      <td>
                        <% days = cert_days((@instance.external[kind] || %{})["cert_expires_at"]) %>
                        <span :if={days} class={days < 14 && "text-warning"}>{days} дн.</span>
                        <span :if={!days} class="text-base-content/40">—</span>
                      </td>
                    </tr>
                  </tbody>
                </table>
                <p class="text-xs text-base-content/60">
                  Диск: {(disk_percent(@instance) && "#{disk_percent(@instance)}% занято") || "—"} ·
                  проверено снаружи {ago(@instance.checked_at)}
                </p>
              </div>
            </section>
          </div>
        </details>
      </div>

      <div :if={@tab == "errors"} id="tab-errors-panel" class="space-y-4">
        <div
          :if={errors_count(@instance, @health) > 0}
          id="errors-summary"
          class="rounded-xl border border-base-300 bg-base-100 p-4 text-sm"
        >
          Ошибки и предупреждения
          <span class="badge badge-error badge-sm ml-2">{errors_count(@instance, @health)}</span>
        </div>
        <section
          :if={latest_errors(@instance) != []}
          id="latest-errors"
          class="rounded-xl border border-base-300 bg-base-100 p-4"
        >
          <h2 class="font-semibold mb-3">Последние ошибки приложения</h2>
          <ul class="space-y-2 text-xs">
            <li
              :for={error <- latest_errors(@instance)}
              class="rounded-lg border border-error/20 bg-error/5 px-3 py-2 break-words"
            >
              <span class="text-base-content/60">{error_time(error["inserted_at"])}</span>
              <span :if={error["source"]} class="font-semibold">{error["source"]}</span>
              {error["message"]}
            </li>
          </ul>
        </section>
        <p
          :if={errors_count(@instance, @health) == 0 && @incidents == []}
          class="text-sm text-base-content/60"
        >
          Ошибок нет
        </p>

        <div :if={@health.problems != []} id="instance-problems" class="alert alert-warning">
          <ul class="list-disc pl-5">
            <li :for={problem <- @health.problems}>{problem}</li>
          </ul>
        </div>

        <div
          :for={{metric, since} <- @instance.load_alerts}
          id={"load-alert-#{metric}"}
          class="alert alert-error py-2 text-sm"
        >
          <.icon name="hero-fire" class="size-5" />
          <span>
            {if metric == "cpu", do: "Процессор", else: "Память"} выше {Bastion.Metrics.Alerts.threshold()}% с {since_label(
              since
            )}
          </span>
        </div>

        <div
          :for={{key, _alert} = alert <- Enum.sort(@instance.site_alerts)}
          id={"site-alert-#{String.replace(key, ":", "-")}"}
          class="alert alert-error py-2 text-sm"
        >
          <.icon name={site_alert_icon(key)} class="size-5" />
          <span>{SiteAlerts.describe(alert)}</span>
        </div>

        <section
          :if={CrmAlerts.problems(@instance) != []}
          id="crm-problems"
          class="rounded-box border border-error/40 bg-error/5 p-4 space-y-2"
        >
          <h2 class="flex items-center gap-2 font-bold text-error">
            <.icon name="hero-exclamation-triangle" class="size-5" /> Заказы не дошли до CRM
          </h2>
          <p class="text-xs text-base-content/70">
            За последние сутки: окончательно не отправленные и висящие в очереди дольше 5 минут.
            Неотправленные заказы нужно передать в CRM вручную, а потом нажать «Убрал».
            В Telegram приходят только заказы, которые окончательно не ушли.
          </p>
          <div class="overflow-x-auto">
            <table class="table table-sm">
              <tbody>
                <tr :for={order <- CrmAlerts.problems(@instance)} id={"crm-order-#{order["id"]}"}>
                  <td class="font-semibold whitespace-nowrap">№{order["number"]}</td>
                  <td class="whitespace-nowrap">
                    <span :if={order["status"] == "failed"} class="badge badge-error badge-sm">
                      не ушёл
                    </span>
                    <span :if={order["status"] != "failed"} class="badge badge-warning badge-sm">
                      в очереди
                    </span>
                  </td>
                  <td class="text-xs">{order["branch"]}</td>
                  <td class="text-xs text-base-content/70 max-w-80 break-words">{order["error"]}</td>
                  <td class="text-xs whitespace-nowrap text-base-content/60">
                    {datetime(CrmAlerts.inserted_at(order))}
                  </td>
                  <td class="text-right">
                    <button
                      type="button"
                      class="btn btn-ghost btn-xs"
                      phx-click="crm_dismiss"
                      phx-value-id={order["id"]}
                      title="Заказ передан вручную или ошибка исправлена"
                    >
                      <.icon name="hero-check" class="size-4" /> Убрал
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>

        <section :if={@incidents != []} class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-3">
            <h2 class="font-bold">Простои</h2>
            <table id="incidents" class="table table-sm">
              <thead>
                <tr>
                  <th>Начало</th>
                  <th>Длительность</th>
                  <th>Причина</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={incident <- @incidents} id={"incident-#{incident.id}"}>
                  <td class="whitespace-nowrap text-xs">{datetime(incident.started_at)}</td>
                  <td class="whitespace-nowrap">
                    {Downtime.format_duration(Downtime.duration(incident))}
                    <span :if={!incident.ended_at} class="badge badge-error badge-sm">идёт</span>
                  </td>
                  <td class="text-xs text-base-content/70">
                    {Enum.join(incident.problems, "; ")}
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </section>
      </div>

      <div :if={@tab == "logs"} id="tab-logs-panel" class="space-y-4">
        <section class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-3">
            <h2 class="font-bold">Логи</h2>
            <.form
              for={@logs_form}
              id="logs-form"
              phx-submit="logs"
              class="flex flex-wrap items-end gap-2"
            >
              <select name="service" class="select select-sm w-40">
                <option value="">все сервисы</option>
                <option
                  :for={service <- services(@instance)}
                  value={service}
                  selected={@logs_form[:service].value == service}
                >
                  {service}
                </option>
              </select>
              <input
                type="number"
                name="tail"
                value={@logs_form[:tail].value}
                min="1"
                max="2000"
                class="input input-sm w-24"
              />
              <button
                type="submit"
                class="btn btn-sm"
                disabled={!@instance.online || busy?(@commands)}
              >
                Показать
              </button>
            </.form>
          </div>
        </section>

        <section class="space-y-2">
          <h2 class="font-bold">Команды и их вывод</h2>
          <div :if={@commands == []} class="text-sm text-base-content/60">Команд ещё не было</div>
          <details
            :for={command <- @commands}
            id={"command-#{command.id}"}
            class="rounded-box border border-base-300 bg-base-100"
            open={command.action == "logs" && command == hd(@commands)}
          >
            <summary class="flex flex-wrap items-center gap-3 p-3 cursor-pointer">
              <span class="font-semibold">{action_label(command.action)}</span>
              <span :if={command.args["service"]} class="text-xs">{command.args["service"]}</span>
              <.command_status status={command.status} />
              <span class="text-xs text-base-content/60">
                {datetime(command.inserted_at)} · {command.requested_by}
              </span>
            </summary>
            <pre
              :if={command.output}
              class="max-h-96 overflow-auto border-t border-base-300 p-3 text-xs whitespace-pre-wrap"
            >{command.output}</pre>
          </details>
        </section>
      </div>

      <div :if={@tab == "backups"} id="tab-backups-panel" class="space-y-4">
        <section id="backups" class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-3">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div>
                <h2 class="font-bold">Бэкапы базы</h2>
                <p class="text-xs text-base-content/60">
                  Каждый день в 00:00 UTC (03:00 МСК) и перед каждым обновлением, хранятся последние {Backups.keep()}.
                  Каждый бэкап бастион целиком читает pg_restore, а если настроено внешнее хранилище, кладёт туда копию.
                  Логи сайта в бэкап не входят.
                  Восстановить можно из бэкапа этой сети или из своего файла.
                  При восстановлении сервер ненадолго выключается, а прежняя база остаётся рядом как
                  &lt;имя базы&gt;_before_restore до следующего восстановления.
                </p>
              </div>
              <button
                id="backup-now"
                type="button"
                class="btn btn-sm"
                phx-click="backup"
                disabled={!@instance.online || busy?(@commands) || !backups_supported?(@instance)}
              >
                <.icon name="hero-circle-stack" class="size-4" /> Сделать бэкап
              </button>
            </div>

            <p :if={!backups_supported?(@instance)} class="text-sm text-warning">
              Агент этого экземпляра не умеет делать бэкапы, сначала обновите экземпляр.
            </p>

            <div class="overflow-x-auto">
              <table id="backup-list" class="table table-sm">
                <tbody>
                  <tr :for={backup <- @backups} id={"backup-#{backup.id}"}>
                    <td class="whitespace-nowrap text-xs">{datetime(backup.inserted_at)}</td>
                    <td class="whitespace-nowrap tabular-nums">{format_size(backup.size)}</td>
                    <td>
                      <span :if={backup.status == "ok"} class="badge badge-success badge-sm">готов</span>
                      <span :if={backup.status == "pending"} class="badge badge-info badge-sm">идёт</span>
                      <span :if={backup.status == "error"} class="badge badge-error badge-sm">ошибка</span>
                      <span
                        :if={backup.verify_status == "ok"}
                        class="badge badge-ghost badge-sm"
                        title="pg_restore прочитал бэкап целиком, данные заказов на месте"
                      >
                        проверен
                      </span>
                      <span :if={backup.verify_status == "error"} class="badge badge-error badge-sm">
                        не читается
                      </span>
                      <span
                        :if={backup.offsite_at}
                        class="badge badge-ghost badge-sm"
                        title="Копия лежит во внешнем хранилище"
                      >
                        <.icon name="hero-cloud-arrow-up-micro" class="size-3" /> копия
                      </span>
                      <span :if={backup.error} class="block text-xs text-error whitespace-pre-wrap">
                        {backup.error}
                      </span>
                      <span
                        :if={backup.verify_error || backup.offsite_error}
                        class="block text-xs text-error whitespace-pre-wrap"
                      >
                        {backup.verify_error || backup.offsite_error}
                      </span>
                    </td>
                    <td class="text-xs text-base-content/60">{backup.requested_by}</td>
                    <td class="text-right whitespace-nowrap">
                      <.link
                        :if={backup.status == "ok"}
                        href={~p"/backups/#{backup.id}/download"}
                        class="btn btn-ghost btn-xs"
                      >
                        <.icon name="hero-arrow-down-tray" class="size-4" /> Скачать
                      </.link>
                      <button
                        :if={backup.status == "ok"}
                        type="button"
                        class="btn btn-ghost btn-xs text-error"
                        phx-click="restore"
                        phx-value-backup_id={backup.id}
                        disabled={
                          !@instance.online || busy?(@commands) || !backups_supported?(@instance)
                        }
                        data-confirm={"Восстановить базу #{@instance.name} из бэкапа от #{datetime(backup.inserted_at)}? Всё, что появилось после него, пропадёт из рабочей базы."}
                      >
                        Восстановить
                      </button>
                    </td>
                  </tr>
                  <tr :if={@backups == []}>
                    <td class="text-base-content/60">Бэкапов ещё нет</td>
                  </tr>
                </tbody>
              </table>
            </div>

            <.form
              for={%{}}
              id="restore-file"
              phx-change="validate_dump"
              phx-submit="restore_file"
              class="flex flex-col gap-2 border-t border-base-300 pt-3"
            >
              <span class="text-sm text-base-content/60">
                Восстановить из своего файла: дамп pg_dump -Fc, например скачанный здесь же .dump.
              </span>
              <div class="flex flex-wrap items-center gap-2">
                <.live_file_input
                  upload={@uploads.dump}
                  class="file-input file-input-sm w-full sm:w-96"
                />
                <button
                  type="submit"
                  class="btn btn-sm btn-error btn-outline"
                  disabled={
                    @uploads.dump.entries == [] || !@instance.online || busy?(@commands) ||
                      !backups_supported?(@instance)
                  }
                  data-confirm={"Заменить базу #{@instance.name} базой из файла? Текущие данные пропадут из рабочей базы."}
                >
                  <.icon name="hero-arrow-up-tray" class="size-4" /> Восстановить из файла
                </button>
              </div>
              <div :for={entry <- @uploads.dump.entries} class="text-xs space-y-1">
                <div class="flex items-center gap-2">
                  <span class="font-semibold">{entry.client_name}</span>
                  <span class="text-base-content/60">{format_size(entry.client_size)}</span>
                  <progress
                    :if={entry.progress > 0}
                    class="progress progress-primary w-32"
                    value={entry.progress}
                    max="100"
                  />
                </div>
                <p :for={error <- upload_errors(@uploads.dump, entry)} class="text-error">
                  {upload_error(error)}
                </p>
              </div>
            </.form>
          </div>
        </section>
      </div>

      <div :if={@tab == "history"} id="tab-history-panel" class="space-y-4">
        <section class="rounded-xl border border-base-300 bg-base-100 p-4 space-y-3">
          <div class="flex flex-wrap items-center justify-between gap-3">
            <h2 class="font-semibold">Последние операции</h2>
            <button
              :if={rollback(@instance)}
              id="rollback"
              type="button"
              class="btn btn-sm btn-outline"
              phx-click="command"
              phx-value-action="rollback"
              disabled={!@instance.online || busy?(@commands)}
              data-confirm={rollback_confirmation(rollback(@instance))}
            >
              <.icon name="hero-arrow-uturn-left" class="size-4" /> Откатить обновление
            </button>
          </div>
          <p class="text-sm">Обновление через Bastion: {operation_label(@operations.update)}</p>
          <p class="text-sm">
            Восстановление бэкапа через Bastion: {operation_label(@operations.restore)}
          </p>
        </section>
        <section
          id="maintenance-history"
          class="rounded-xl border border-base-300 bg-base-100 p-4 space-y-3"
        >
          <h2 class="font-semibold">Окна обслуживания</h2>
          <p :if={@maintenance_windows == []} class="text-sm text-base-content/60">Пока не было</p>
          <div
            :for={window <- @maintenance_windows}
            id={"maintenance-window-#{window.id}"}
            class="border-t border-base-200 pt-2 text-sm"
          >
            {datetime(window.started_at)} — {datetime(window.ended_at || window.scheduled_end_at)}
            <span :if={is_nil(window.ended_at) && Maintenance.active?(@instance)} class="text-sky-700">· идёт</span>
          </div>
        </section>
      </div>

      <div :if={@tab == "settings"} id="tab-settings-panel" class="space-y-4">
        <section id="env" class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-3">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div>
                <h2 class="font-bold">Переменные окружения (.env)</h2>
                <p class="text-xs text-base-content/60">
                  После сохранения прежний файл остаётся в .env.bak, а сервисы пересоздаются с новыми значениями.
                  Свои переменные агент подхватит только после ручного перезапуска.
                </p>
              </div>
              <button
                id="env-load"
                type="button"
                class="btn btn-sm"
                phx-click="env_load"
                disabled={
                  !@instance.online || busy?(@commands) || !env_supported?(@instance) || @env_request
                }
              >
                <span :if={@env_request} class="loading loading-spinner loading-xs"></span>
                <.icon :if={!@env_request} name="hero-arrow-down-tray" class="size-4" />
                {if @env_loaded?, do: "Перечитать", else: "Загрузить"}
              </button>
            </div>
            <div
              :if={missing_env(@instance) != []}
              id="env-missing"
              class="alert alert-warning py-2 text-sm"
            >
              <.icon name="hero-exclamation-triangle" class="size-5" />
              <span>
                В .env нет переменных, которые есть в .env.example новой версии: <span class="font-mono">{Enum.join(missing_env(@instance), ", ")}</span>.
                Добавьте их, если они нужны этому сайту.
              </span>
            </div>
            <p :if={!env_supported?(@instance)} class="text-sm text-warning">
              Агент этого экземпляра не умеет работать с .env, сначала обновите экземпляр.
            </p>
            <.form
              :if={@env_loaded?}
              for={@env_form}
              id="env-form"
              phx-change="env_change"
              phx-submit="env_save"
              class="space-y-2"
            >
              <textarea
                name="content"
                rows="18"
                spellcheck="false"
                autocomplete="off"
                class="textarea w-full font-mono text-xs leading-relaxed"
              >{Phoenix.HTML.Form.normalize_value("textarea", @env_form[:content].value)}</textarea>
              <button
                type="submit"
                class="btn btn-primary btn-sm"
                disabled={!@instance.online || busy?(@commands)}
                data-confirm="Сохранить .env и пересоздать сервисы с новыми значениями?"
              >
                <.icon name="hero-check" class="size-4" /> Сохранить и применить
              </button>
            </.form>
          </div>
        </section>

        <section id="agent" class="card bg-base-100 border border-base-300">
          <div class="card-body p-4 gap-3">
            <div class="flex flex-wrap items-start justify-between gap-2">
              <div>
                <h2 class="font-bold">Агент</h2>
                <p class="text-xs text-base-content/60">
                  Версия {@instance.agent_version || "—"} · образ
                  <span class="font-mono">{agent_revision(@instance)}</span>
                  <span :if={Images.agent_outdated?(@instance)} class="badge badge-info badge-xs ml-1">
                    есть новее
                  </span>
                </p>
                <p class="text-xs text-base-content/60">
                  Агент скачает свой новый образ и пересоздаст себя, заодно подхватит новый .env.
                  Сайт при этом работает, бастион на несколько секунд потеряет связь с агентом.
                </p>
              </div>
              <button
                :if={"agent_update" in @instance.actions}
                id="agent-update"
                type="button"
                class="btn btn-sm"
                phx-click="command"
                phx-value-action="agent_update"
                disabled={!@instance.online || busy?(@commands)}
                data-confirm="Обновить агента? Он перезапустится через несколько секунд."
              >
                <.icon name="hero-arrow-path" class="size-4" /> Обновить агента
              </button>
            </div>
            <p :if={"agent_update" not in @instance.actions} class="text-sm text-warning">
              Этот агент не умеет обновлять себя. Один раз обновите его на сервере:
              <code class="font-mono text-xs">docker compose pull agent && docker compose up -d agent</code>
            </p>
          </div>
        </section>

        <section
          id="instance-management"
          class="rounded-xl border border-base-300 bg-base-100 p-4 space-y-3"
        >
          <h2 class="font-semibold">Управление</h2>
          <button
            id="instance-restart"
            type="button"
            class="btn btn-sm"
            phx-click="command"
            phx-value-action="restart"
            disabled={!@instance.online || busy?(@commands)}
            data-confirm="Перезапустить сайт?"
          >Перезапустить</button>
        </section>
        <div id="danger-zone" class="mt-6 rounded-xl border border-error/30 bg-error/5 p-4 space-y-3">
          <h2 class="font-semibold">Опасные действия</h2>
          <button
            id="instance-stop"
            type="button"
            class="btn btn-sm btn-error btn-outline"
            phx-click="command"
            phx-value-action="stop"
            disabled={!@instance.online || busy?(@commands)}
            data-confirm="Выключить сайт? Агент останется на связи."
          >
            Выключить сайт
          </button>
          <button
            id="delete-instance"
            type="button"
            class="btn btn-ghost btn-sm text-error"
            phx-click="delete"
            data-confirm="Удалить экземпляр из бастиона? Если агент снова подключится, экземпляр появится заново."
          >
            Удалить из бастиона
          </button>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
