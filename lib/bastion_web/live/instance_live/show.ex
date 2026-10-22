defmodule BastionWeb.InstanceLive.Show do
  use BastionWeb, :live_view

  import BastionWeb.InstanceLive.Components

  alias Bastion.{Backups, Downtime, Health, Instances}
  alias BastionWeb.Presence

  @tick :timer.seconds(15)

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
           env_loaded?: false
         )
         |> assign_instance(instance)
         |> load_commands()
         |> load_backups()}
    end
  end

  @impl true
  def handle_event("command", %{"action" => action}, socket) do
    {:noreply, send_command(socket, action, %{})}
  end

  def handle_event("logs", %{"service" => service, "tail" => tail}, socket) do
    socket = assign(socket, logs_form: to_form(%{"service" => service, "tail" => tail}))
    {:noreply, send_command(socket, "logs", %{"service" => service, "tail" => tail})}
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

  def handle_event("backup", _params, socket) do
    socket =
      case Backups.start(socket.assigns.instance, socket.assigns.current_admin) do
        {:ok, _backup} -> put_flash(socket, :info, "Агент делает бэкап")
        {:error, reason} -> put_flash(socket, :error, "Бэкап не начат: #{reason}")
      end

    {:noreply, load_backups(socket)}
  end

  def handle_event("restore", %{"backup_id" => backup_id}, socket) do
    socket =
      with %{status: "ok"} = backup <- Backups.get(backup_id),
           {:ok, _command} <-
             Backups.restore(socket.assigns.instance, backup, socket.assigns.current_admin) do
        put_flash(socket, :info, "Агент восстанавливает базу из бэкапа")
      else
        {:error, :offline} ->
          put_flash(socket, :error, "Агент не на связи")

        {:error, :unsupported} ->
          put_flash(socket, :error, "Агент не умеет восстанавливать, обновите экземпляр")

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

  def handle_info(:tick, socket), do: {:noreply, reload(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

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
      incidents: Downtime.list_incidents(instance.id)
    )
  end

  defp load_backups(socket) do
    id = socket.assigns.instance.id

    assign(socket,
      backups: Backups.list(id),
      other_backups: Enum.reject(Backups.list_restorable(), &(&1.instance_id == id))
    )
  end

  defp backups_supported?(instance), do: Backups.supported?(instance)

  defp format_size(nil), do: "—"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{max(div(bytes, 1024), 1)} КБ"
  defp format_size(bytes), do: :erlang.float_to_binary(bytes / 1_048_576, decimals: 1) <> " МБ"

  defp load_commands(socket),
    do: assign(socket, commands: Instances.list_commands(socket.assigns.instance.id))

  defp containers(%{status: %{"containers" => containers}}), do: containers
  defp containers(_instance), do: []

  defp services(instance),
    do: instance |> containers() |> Enum.map(& &1["service"]) |> Enum.filter(&is_binary/1)

  defp env_supported?(instance), do: "env_write" in instance.actions

  defp busy?(commands), do: Enum.any?(commands, &(&1.status in ["sent", "running"]))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <.link navigate={~p"/"} class="btn btn-ghost btn-sm -ml-2">
        <.icon name="hero-arrow-left" class="size-4" /> Все экземпляры
      </.link>

      <div class="flex flex-wrap items-start justify-between gap-4">
        <div class="space-y-1">
          <div class="flex items-center gap-3">
            <.online_dot online={@instance.online} />
            <h1 class="text-2xl font-bold">{@instance.name}</h1>
            <.health_badge level={@health.level} />
          </div>
          <div class="text-sm text-base-content/60 flex flex-wrap gap-x-4">
            <a
              :for={{kind, host} <- Enum.sort(@instance.hosts)}
              href={"https://#{host}"}
              target="_blank"
              class="link link-hover"
            >
              {kind}: {host}
            </a>
          </div>
          <div class="text-xs text-base-content/60">
            Последний контакт: {ago(@instance.last_seen_at)} · агент {@instance.agent_version || "—"}
          </div>
        </div>

        <div id="instance-actions" class="flex flex-wrap gap-2">
          <button
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
            type="button"
            class="btn btn-sm"
            phx-click="command"
            phx-value-action="restart"
            disabled={!@instance.online || busy?(@commands)}
            data-confirm="Перезапустить сайт?"
          >
            Перезапустить
          </button>
          <button
            type="button"
            class="btn btn-sm"
            phx-click="command"
            phx-value-action="start"
            disabled={!@instance.online || busy?(@commands)}
          >
            Включить
          </button>
          <button
            type="button"
            class="btn btn-sm btn-error btn-outline"
            phx-click="command"
            phx-value-action="stop"
            disabled={!@instance.online || busy?(@commands)}
            data-confirm="Выключить сайт? Агент останется на связи."
          >
            Выключить
          </button>
        </div>
      </div>

      <div :if={@instance.stopped_at} id="instance-stopped" class="alert alert-info">
        <.icon name="hero-pause-circle" class="size-5" />
        <span>
          Сайт выключен по плану {datetime(@instance.stopped_at)}. Пока его не включат,
          недоступность не считается ошибкой и уведомления не приходят.
        </span>
      </div>

      <div :if={@health.problems != []} id="instance-problems" class="alert alert-warning">
        <ul class="list-disc pl-5">
          <li :for={problem <- @health.problems}>{problem}</li>
        </ul>
      </div>

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
                  <td class="font-mono text-xs">{String.slice(container["revision"] || "", 0, 7)}</td>
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
                  <td class="font-semibold">{if kind == "api", do: "API", else: "Сайт"}</td>
                  <td><.check check={(@instance.status || %{})["checks"][kind]} /></td>
                  <td><.check check={@instance.external[kind]} /></td>
                  <td>
                    <% days = cert_days(@instance.external[kind]["cert_expires_at"]) %>
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
          <table :if={@incidents != []} id="incidents" class="table table-sm">
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
          <p :if={@incidents == []} class="text-sm text-base-content/60">Простоев не было</p>
        </div>
      </section>

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

      <section id="backups" class="card bg-base-100 border border-base-300">
        <div class="card-body p-4 gap-3">
          <div class="flex flex-wrap items-start justify-between gap-2">
            <div>
              <h2 class="font-bold">Бэкапы базы</h2>
              <p class="text-xs text-base-content/60">
                Каждый день в 00:00 UTC (03:00 МСК), хранятся последние {Backups.keep()}. Логи сайта в бэкап не входят.
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
                    <span :if={backup.error} class="block text-xs text-error whitespace-pre-wrap">
                      {backup.error}
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
            :if={@other_backups != []}
            for={%{}}
            id="restore-other"
            phx-submit="restore"
            class="flex flex-wrap items-end gap-2 border-t border-base-300 pt-3"
          >
            <label class="flex flex-col gap-1 text-sm">
              <span class="text-base-content/60">Развернуть сюда бэкап другой сети</span>
              <select name="backup_id" class="select select-sm w-full sm:w-96">
                <option :for={backup <- @other_backups} value={backup.id}>
                  {backup.instance_name} · {datetime(backup.inserted_at)} · {format_size(backup.size)}
                </option>
              </select>
            </label>
            <button
              type="submit"
              class="btn btn-sm btn-error btn-outline"
              disabled={!@instance.online || busy?(@commands) || !backups_supported?(@instance)}
              data-confirm={"Заменить базу #{@instance.name} базой из выбранного бэкапа? Текущие данные этой сети пропадут из рабочей базы."}
            >
              Восстановить
            </button>
          </.form>
        </div>
      </section>

      <section class="space-y-2">
        <h2 class="font-bold">Команды</h2>
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

      <div class="pt-4 border-t border-base-300">
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
    </Layouts.app>
    """
  end
end
