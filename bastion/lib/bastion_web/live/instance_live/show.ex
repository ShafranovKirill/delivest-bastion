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
    Releases,
    SiteAlerts,
    Snapshots,
    ManagedSnapshots,
    Nodes,
    ManagedInstances,
    Domains
  }

  alias BastionWeb.Presence

  @tick :timer.seconds(15)
  @tabs [
    {"state", "Мониторинг"},
    {"updates", "Обновления"},
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
        {:ok,
         socket |> put_flash(:error, "Экземпляр не найден") |> push_navigate(to: ~p"/instances")}

      instance ->
        if connected?(socket) do
          Instances.subscribe()
          Nodes.subscribe()
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
           release_form: to_form(%{}, as: :release),
           delete_form: to_form(%{"confirm_instance_id" => ""}, as: :delete),
           restore_check_form: to_form(%{"evidence" => ""}, as: :restore_check),
           agent_release_form: to_form(%{}, as: :agent_release),
           latest_release: nil,
           latest_loading?: false,
           latest_error?: false,
           maintenance_open?: false,
           metrics_period: :day,
           client_form:
             to_form(Bastion.Instances.Instance.client_changeset(instance, %{}), as: :client),
           editing_client?: false,
           revealed_password: nil,
           tab: "client",
           open_modules: MapSet.new()
         )
         |> allow_upload(:dump, accept: :any, max_entries: 1, max_file_size: @max_dump_size)
         |> assign_instance(instance)
         |> load_commands()
         |> load_backups()
         |> load_metrics()
         |> maybe_fetch_managed_latest()}
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if Enum.any?(@tabs, &(elem(&1, 0) == params["tab"])), do: params["tab"], else: "client"
    open_modules = if tab == "client", do: MapSet.new(), else: MapSet.new([tab])
    socket = assign(socket, tab: tab, open_modules: open_modules)

    socket =
      if tab in ["updates", "settings"] and is_nil(socket.assigns.latest_release) and
           !socket.assigns.latest_loading? and !socket.assigns.latest_error? do
        fetch_latest(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("toggle_module", %{"module" => module}, socket) do
    modules = socket.assigns.open_modules

    modules =
      if MapSet.member?(modules, module),
        do: MapSet.delete(modules, module),
        else: MapSet.put(modules, module)

    socket = assign(socket, open_modules: modules)

    socket =
      if module in ["updates", "settings"] and MapSet.member?(modules, module) and
           is_nil(socket.assigns.latest_release) and !socket.assigns.latest_loading? and
           !socket.assigns.latest_error? do
        fetch_latest(socket)
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("edit_client", _params, socket) do
    {:noreply,
     assign(socket,
       editing_client?: true,
       revealed_password: nil,
       client_form:
         to_form(Bastion.Instances.Instance.client_changeset(socket.assigns.instance, %{}),
           as: :client
         )
     )}
  end

  def handle_event("cancel_client", _params, socket) do
    {:noreply,
     assign(socket,
       editing_client?: false,
       revealed_password: nil,
       client_form:
         to_form(Bastion.Instances.Instance.client_changeset(socket.assigns.instance, %{}),
           as: :client
         )
     )}
  end

  def handle_event("save_client", %{"client" => attrs}, socket) do
    case Instances.update_client(socket.assigns.instance, attrs) do
      {:ok, instance} ->
        {:noreply,
         socket
         |> assign_instance(instance)
         |> assign(
           editing_client?: false,
           revealed_password: nil,
           client_form:
             to_form(Bastion.Instances.Instance.client_changeset(instance, %{}), as: :client)
         )
         |> put_flash(:info, "Данные сохранены")}

      {:error, changeset} ->
        changeset = Ecto.Changeset.delete_change(changeset, :admin_password)
        {:noreply, assign(socket, client_form: to_form(changeset, as: :client))}
    end
  end

  def handle_event("reveal_password", _params, socket) do
    case Bastion.Credentials.decrypt(socket.assigns.instance.admin_password_encrypted) do
      {:ok, password} ->
        {:noreply, assign(socket, revealed_password: password)}

      {:error, _} ->
        {:noreply,
         put_flash(socket, :error, "Не удалось расшифровать пароль. Сохраните его заново.")}
    end
  end

  def handle_event("hide_password", _params, socket),
    do: {:noreply, assign(socket, revealed_password: nil)}

  def handle_event("install_release", _params, socket) do
    socket =
      case if(socket.assigns.latest_loading?, do: nil, else: socket.assigns.latest_release) do
        nil ->
          {:error, :release_unavailable}

        bundle ->
          Bastion.Updates.update(
            socket.assigns.instance,
            bundle.version,
            socket.assigns.current_admin
          )
      end
      |> case do
        {:ok, command} ->
          show_logs(socket, command)

        {:error, :offline} ->
          put_flash(socket, :error, "Агент не на связи")

        {:error, :agent_upgrade_required} ->
          put_flash(socket, :error, "Сначала обновите агент")

        {:error, :invalid_version} ->
          put_flash(socket, :error, "Неверный формат версии")

        {:error, :already_current} ->
          put_flash(socket, :info, "Уже установлена эта или более новая версия")

        {:error, reason} ->
          put_flash(socket, :error, release_error(reason))
      end

    {:noreply, socket}
  end

  def handle_event("install_agent_release", _params, socket) do
    socket =
      case if(socket.assigns.latest_loading?, do: nil, else: socket.assigns.latest_release) do
        nil ->
          put_flash(socket, :error, "Не удалось получить последний релиз")

        bundle ->
          current =
            get_in(socket.assigns.instance.status || %{}, ["agent", "version"]) ||
              socket.assigns.instance.agent_version

          if Releases.newer?(bundle.version, current),
            do:
              send_command(socket, "agent_update", %{"release" => bundle.manifest}, &show_logs/2),
            else: put_flash(socket, :info, "Агент уже актуален")
      end

    {:noreply, socket}
  end

  def handle_event("refresh_latest", _params, socket), do: {:noreply, fetch_latest(socket)}

  def handle_event("managed_command", %{"action" => action}, socket) do
    case Nodes.queue(socket.assigns.instance.id, action, socket.assigns.current_admin) do
      {:ok, _operation} ->
        {:noreply,
         socket
         |> assign_instance(socket.assigns.instance)
         |> put_flash(:info, "Команда поставлена в очередь")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Команда не принята: #{inspect(reason)}")}
    end
  end

  def handle_event("managed_release_domain", %{"binding-id" => id}, socket) do
    if Enum.any?(socket.assigns.domain_bindings, &(&1.id == id)) do
      case Domains.request_release(id, socket.assigns.current_admin) do
        {:ok, _} ->
          {:noreply, socket |> reload() |> put_flash(:info, "Освобождение адреса запущено")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Адрес не освобождён: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Адрес не принадлежит франшизе")}
    end
  end

  def handle_event("managed_delete", %{"delete" => %{"confirm_instance_id" => id}}, socket) do
    if id == socket.assigns.instance.id do
      case Nodes.queue(id, "instance_delete", socket.assigns.current_admin, %{
             "confirm_instance_id" => id
           }) do
        {:ok, _} ->
          {:noreply, socket |> reload() |> put_flash(:info, "Удаление установки запущено")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Удаление не запущено: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Укажите точный ID франшизы")}
    end
  end

  def handle_event("managed_retry_create", _, socket) do
    case ManagedInstances.retry_create(socket.assigns.instance.id) do
      {:ok, _} ->
        {:noreply,
         socket |> reload() |> put_flash(:info, "Повтор создания запущен с прежним ID и релизом")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Повтор невозможен: #{inspect(reason)}")}
    end
  end

  def handle_event("managed_cleanup", _, socket) do
    case ManagedInstances.request_cleanup(
           socket.assigns.instance.id,
           socket.assigns.current_admin
         ) do
      {:ok, _} ->
        {:noreply,
         socket
         |> reload()
         |> put_flash(:info, "Очистка неудачной установки запущена; данные сохранены")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Очистка невозможна: #{inspect(reason)}")}
    end
  end

  def handle_event("managed_prepare_domain", %{"binding-id" => id}, socket) do
    case Domains.request_prepare(id, nil, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Подготовка нового адреса запущена")}

      {:error, :waiting_dns} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Ожидаем DNS")}

      {:error, reason} ->
        {:noreply, socket |> reload() |> put_flash(:error, "Адрес не готов: #{inspect(reason)}")}
    end
  end

  def handle_event("managed_confirm_browser", %{"binding-id" => id}, socket) do
    case ManagedInstances.confirm_browser(id, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Проверка браузером записана")}

      {:error, reason} ->
        {:noreply,
         socket |> reload() |> put_flash(:error, "Проверка не принята: #{inspect(reason)}")}
    end
  end

  def handle_event("managed_activate_domain", %{"binding-id" => id}, socket) do
    case ManagedInstances.activate(id, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Переключение запущено")}

      {:error, reason} ->
        {:noreply,
         socket |> reload() |> put_flash(:error, "Переключение невозможно: #{inspect(reason)}")}
    end
  end

  def handle_event("managed_retry_rollback", _, socket) do
    case ManagedInstances.retry_rollback(
           socket.assigns.instance.id,
           socket.assigns.current_admin
         ) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Повтор отката запущен")}

      {:error, reason} ->
        {:noreply,
         socket |> reload() |> put_flash(:error, "Повтор отката невозможен: #{inspect(reason)}")}
    end
  end

  def handle_event("rename_managed", %{"instance" => %{"name" => name}}, socket) do
    case Nodes.rename_instance(socket.assigns.instance.id, name) do
      {:ok, instance} ->
        {:noreply, socket |> assign_instance(instance) |> put_flash(:info, "Название сохранено")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Не удалось сохранить название")}
    end
  end

  def handle_event("command", %{"action" => "agent_update"}, socket) do
    if "release_manifest_v1" in socket.assigns.instance.capabilities do
      handle_event("install_agent_release", %{}, socket)
    else
      {:noreply, send_command(socket, "agent_update", %{}, &show_logs/2)}
    end
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

  def handle_event("full_snapshot", _params, socket) do
    socket =
      case Snapshots.start(socket.assigns.instance, socket.assigns.current_admin) do
        {:ok, _snapshot} ->
          put_flash(socket, :info, "Агент создаёт полный слепок")

        {:error, reason} ->
          put_flash(socket, :error, "Слепок не начат: #{snapshot_error(reason)}")
      end

    {:noreply, load_backups(socket)}
  end

  def handle_event("managed_snapshot", _, socket) do
    socket =
      case ManagedSnapshots.start(socket.assigns.instance, socket.assigns.current_admin) do
        {:ok, _} -> put_flash(socket, :info, "Нода создаёт полную копию")
        {:error, reason} -> put_flash(socket, :error, "Копия не начата: #{inspect(reason)}")
      end

    {:noreply, load_backups(socket)}
  end

  def handle_event(
        "managed_restore_checked",
        %{"snapshot_id" => id, "restore_check" => %{"evidence" => evidence}},
        socket
      ) do
    if socket.assigns.instance.transport == "node" and socket.assigns.managed_snapshot_latest &&
         socket.assigns.managed_snapshot_latest.id == id do
      case ManagedSnapshots.confirm_restore(id, socket.assigns.current_admin, evidence) do
        {:ok, _} ->
          {:noreply,
           socket |> load_backups() |> put_flash(:info, "Проверка восстановления записана")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Проверка не записана: #{inspect(reason)}")}
      end
    else
      {:noreply, put_flash(socket, :error, "Выберите текущую полную копию")}
    end
  end

  def handle_event("managed_retry_prune", _, socket) do
    case socket.assigns.managed_snapshot_latest do
      %{restore_checked_at: checked, restore_evidence: evidence, error: error} = snapshot
      when not is_nil(checked) and not is_nil(error) ->
        case ManagedSnapshots.confirm_restore(snapshot.id, socket.assigns.current_admin, evidence) do
          {:ok, _} ->
            {:noreply,
             socket |> load_backups() |> put_flash(:info, "Очистка прежних копий повторена")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Очистка не выполнена: #{inspect(reason)}")}
        end

      _ ->
        {:noreply, socket}
    end
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

  def handle_event("delete", _params, %{assigns: %{instance: %{transport: "node"}}} = socket) do
    {:noreply,
     put_flash(socket, :error, "Удаление управляемой франшизы требует отдельной операции")}
  end

  def handle_event("delete", _params, socket) do
    {:ok, _} = Instances.delete_instance(socket.assigns.instance)

    {:noreply,
     socket |> put_flash(:info, "Экземпляр удалён") |> push_navigate(to: ~p"/instances")}
  end

  @impl true
  def handle_async(:latest_release, {:ok, {:ok, bundle}}, socket),
    do:
      {:noreply,
       assign(socket, latest_release: bundle, latest_loading?: false, latest_error?: false)}

  def handle_async(:latest_release, _result, socket),
    do:
      {:noreply, assign(socket, latest_release: nil, latest_loading?: false, latest_error?: true)}

  def handle_async(:managed_latest, {:ok, {:ok, release}}, socket),
    do: {:noreply, assign(socket, managed_latest: release.version)}

  def handle_async(:managed_latest, _result, socket),
    do: {:noreply, assign(socket, managed_latest: nil)}

  defp maybe_fetch_managed_latest(socket) do
    socket = assign(socket, managed_latest: nil)

    if connected?(socket) and socket.assigns.instance.transport == "node",
      do: start_async(socket, :managed_latest, fn -> Releases.Managed.latest() end),
      else: socket
  end

  defp fetch_latest(socket) do
    if connected?(socket) do
      socket
      |> assign(latest_release: nil, latest_loading?: true, latest_error?: false)
      |> start_async(:latest_release, fn -> Releases.latest() end)
    else
      socket
    end
  end

  @impl true
  def handle_info({:instance_updated, %{id: id}}, %{assigns: %{instance: %{id: id}}} = socket),
    do: {:noreply, reload(socket)}

  def handle_info({:instance_deleted, %{id: id}}, %{assigns: %{instance: %{id: id}}} = socket),
    do: {:noreply, push_navigate(socket, to: ~p"/instances")}

  def handle_info(
        {:command_updated, %{instance_id: id} = command},
        %{assigns: %{instance: %{id: id}}} = socket
      ) do
    socket =
      if command.id == socket.assigns.env_request and command.status == "error",
        do: assign(socket, env_request: nil),
        else: socket

    {:noreply,
     socket
     |> load_commands()
     |> assign(last_update_command: Instances.last_update_command(id))}
  end

  def handle_info({:backup_updated, _backup}, socket), do: {:noreply, load_backups(socket)}
  def handle_info({:snapshot_updated, _snapshot}, socket), do: {:noreply, load_backups(socket)}
  def handle_info(:nodes_updated, socket), do: {:noreply, reload(socket)}

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
      nil -> push_navigate(socket, to: ~p"/instances")
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
      last_update_command: Instances.last_update_command(instance.id),
      maintenance_windows: Maintenance.windows(instance),
      node_placement: Nodes.placement_for(instance.id),
      node_operations: Nodes.operations_for(instance.id),
      domain_bindings:
        if(instance.transport == "node", do: ManagedInstances.bindings(instance.id), else: [])
    )
  end

  defp load_backups(socket) do
    id = socket.assigns.instance.id

    assign(socket,
      backups: Backups.list(id),
      snapshot_latest: Snapshots.latest(id),
      snapshot_current: Snapshots.current(id),
      managed_snapshot_latest: ManagedSnapshots.latest(id),
      managed_snapshot_current: ManagedSnapshots.current(id),
      managed_snapshot_restore_checked: ManagedSnapshots.last_restore_checked(id)
    )
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
  defp snapshots_supported?(instance), do: Snapshots.supported?(instance)
  defp snapshot_error(:busy), do: "уже выполняется другая операция"
  defp snapshot_error(:offline), do: "агент не на связи"
  defp snapshot_error(:unsupported), do: "агент не поддерживает полный слепок"
  defp snapshot_error(:storage_unavailable), do: "хранилище не настроено"
  defp snapshot_error(reason), do: inspect(reason)
  defp snapshot_stale?(nil), do: false

  defp snapshot_stale?(snapshot),
    do: DateTime.diff(DateTime.utc_now(), snapshot.finished_at) > 86_400

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

  defp agent_revision(%{status: %{"agent" => %{"version" => version}}}) when is_binary(version),
    do: version

  defp agent_revision(%{status: %{"agent" => %{"revision" => revision}}})
       when is_binary(revision),
       do: String.slice(revision, 0, 7)

  defp agent_revision(_instance), do: "—"

  defp release_error(:release_required), do: "Выберите опубликованную версию"
  defp release_error(:missing_manifest), do: "У релиза нет release-manifest.json"
  defp release_error(:invalid_manifest), do: "Манифест релиза неполон или повреждён"
  defp release_error(:agent_upgrade_required), do: "Сначала обновите агент"
  defp release_error(:invalid_version), do: "Неверный формат версии"
  defp release_error(_), do: "Не удалось получить опубликованный релиз"

  defp confirmed_release(%{status: %{"rollback" => %{"current" => current}}})
       when is_map(current),
       do: current

  defp confirmed_release(_), do: %{}

  defp last_attempt(%{status: %{"rollback" => %{"attempt" => attempt}}})
       when is_map(attempt),
       do: attempt

  defp last_attempt(_), do: %{}

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

  defp busy?(commands), do: Enum.any?(commands, &(&1.status in ["sent", "running"]))

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
        navigate={~p"/instances"}
        class="inline-flex items-center gap-1 text-sm text-base-content/60 hover:text-base-content"
      >
        <.icon name="hero-arrow-left" class="size-4" /> Все франшизы
      </.link>

      <div class="flex flex-wrap items-start justify-between gap-5">
        <div class="space-y-1">
          <div class="flex items-center gap-3">
            <h1 class="text-2xl font-bold">{@instance.name}</h1>
            <.site_status instance={@instance} level={@health.level} />
          </div>
        </div>
      </div>

      <section
        :if={@instance.transport == "node"}
        class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-4"
      >
        <div class="flex flex-wrap items-center justify-between gap-3">
          <h2 class="text-lg font-semibold">Управление через Delivest Node</h2>
          <.link
            :if={@node_placement}
            navigate={~p"/nodes/#{@node_placement.node_id}"}
            class="link text-sm"
          >{@node_placement && @node_placement.node.name}</.link>
        </div>
        <p :if={@node_placement} class="text-sm text-base-content/60">
          Compose-проект {@node_placement.project_name} · 127.0.0.1:{@node_placement.gateway_port} · Фактически {@node_placement.observed_state ||
            "нет данных"} · Цель {@instance.desired_state || "не задана"}
        </p>
        <p class="text-sm text-base-content/60">
          Установлен {@node_placement && (@node_placement.observed_release || "нет данных")} · опубликован {@managed_latest ||
            "нет данных"}
        </p>
        <div :if={@node_placement} class="flex flex-wrap gap-2">
          <button
            :for={action <- ~w(status diagnostics stop start)}
            type="button"
            class="btn btn-sm"
            phx-click="managed_command"
            phx-value-action={action}
          >{action}</button>
        </div>
        <div id="managed-backups" class="rounded-lg bg-base-200 p-3 space-y-2 text-sm">
          <div class="flex flex-wrap items-center justify-between gap-2">
            <h3 class="font-semibold">Полная резервная копия</h3>
            <button
              id="managed-snapshot-now"
              type="button"
              class="btn btn-sm"
              phx-click="managed_snapshot"
              disabled={@managed_snapshot_current && @managed_snapshot_current.status == "pending"}
              data-confirm="Создать полную копию? Выбранная франшиза остановится на время копирования."
            >Создать копию</button>
          </div>
          <p :if={@managed_snapshot_current && @managed_snapshot_current.status == "pending"}>
            Копирование выполняется.
          </p>
          <p
            :if={@managed_snapshot_current && @managed_snapshot_current.status == "error"}
            class="text-error"
          >
            Последняя попытка завершилась ошибкой: {@managed_snapshot_current.error}
          </p>
          <p :if={@managed_snapshot_latest}>
            Последняя копия: {datetime(@managed_snapshot_latest.finished_at)} · {format_size(
              @managed_snapshot_latest.size
            )} · целостность архива проверена · {if @managed_snapshot_latest.restore_checked_at,
              do: "восстановление проверено",
              else: "восстановление не проверено"}
          </p>
          <p :if={@managed_snapshot_restore_checked} id="managed-restore-point">
            Последняя подтверждённая точка восстановления: {datetime(
              @managed_snapshot_restore_checked.finished_at
            )}
          </p>
          <.link
            :if={@managed_snapshot_latest}
            id="managed-snapshot-download"
            href={~p"/backups/snapshots/#{@managed_snapshot_latest.id}/download"}
            class="btn btn-sm btn-outline"
          >
            Скачать копию
          </.link>
          <p :if={!@managed_snapshot_latest}>Пригодной копии пока нет.</p>
          <p :if={@managed_snapshot_latest && @managed_snapshot_latest.error} class="text-warning">
            {@managed_snapshot_latest.error}
          </p>
          <button
            :if={
              @managed_snapshot_latest && @managed_snapshot_latest.restore_checked_at &&
                @managed_snapshot_latest.error
            }
            type="button"
            class="btn btn-xs"
            phx-click="managed_retry_prune"
          >
            Повторить очистку прежних копий
          </button>
          <.form
            :if={@managed_snapshot_latest && !@managed_snapshot_latest.restore_checked_at}
            for={@restore_check_form}
            id="managed-restore-check-form"
            phx-submit="managed_restore_checked"
            class="space-y-2"
          >
            <input type="hidden" name="snapshot_id" value={@managed_snapshot_latest.id} />
            <.input
              field={@restore_check_form[:evidence]}
              label="Протокол изолированного восстановления"
              required
              minlength="10"
            />
            <button
              type="submit"
              class="btn btn-sm btn-outline"
              data-confirm="Подтвердить фактически выполненное восстановление этой копии? После отметки предыдущая копия может быть удалена по политике хранения."
            >
              Подтвердить проверку восстановления
            </button>
          </.form>
          <p
            :if={@managed_snapshot_latest && snapshot_stale?(@managed_snapshot_latest)}
            class="text-warning"
          >
            Последней копии больше суток.
          </p>
        </div>
        <div
          :if={diagnostics = Enum.find(@node_operations, &(&1.action == "diagnostics"))}
          id="managed-diagnostics"
          class="rounded-lg bg-base-200 p-3 text-sm"
        >
          Диагностика: {diagnostics.status} · {inspect(diagnostics.result)}
        </div>
        <div id="managed-creation" class="rounded-lg bg-base-200 p-3 text-sm space-y-2">
          <p>
            Релиз: {@instance.desired_release || "не выбран"}. Создание: {case Enum.find(
                                                                                 @node_operations,
                                                                                 &(&1.action ==
                                                                                     "instance_create")
                                                                               ) do
              nil -> "не начато"
              op -> op.progress["stage"] || op.status
            end}.
          </p>
          <div class="flex gap-2">
            <button id="managed-retry-create" class="btn btn-sm" phx-click="managed_retry_create">Повторить создание</button>
            <button
              id="managed-cleanup"
              class="btn btn-sm btn-outline"
              phx-click="managed_cleanup"
              data-confirm="Очистить только неудачную установку? Данные остаются на ноде."
            >Очистить неудачную</button>
          </div>
        </div>
        <div id="managed-domains" class="space-y-2">
          <h3 class="font-semibold">Адреса</h3>
          <div :if={rollback = Enum.find(@node_operations, &(&1.action == "domain_rollback"))}>
            <p :if={rollback.status in ~w(error unknown)} class="text-sm text-warning">
              Откат адреса не завершён: {rollback.status}. Старый адрес остаётся основным в Bastion.
            </p>
            <button
              :if={rollback.status in ~w(error unknown)}
              id="managed-retry-rollback"
              class="btn btn-sm btn-warning"
              phx-click="managed_retry_rollback"
            >Повторить откат</button>
          </div>
          <p class="text-sm text-base-content/60">
            Добавьте новый домен в разделе «Домены», затем подготовьте его при работающем сайте. После проверки HTTPS откройте адрес в браузере и подтвердите проверку.
          </p>
          <.link navigate={~p"/domains"} class="link text-sm">Реестр доменов</.link>
          <div
            :for={binding <- @domain_bindings}
            id={"binding-#{binding.id}"}
            class="flex flex-wrap items-center gap-2 text-sm rounded-lg border p-3"
          >
            <span>{binding.purpose}: {binding.domain.hostname}</span>
            <span>{binding.state}{if binding.primary, do: " · основной", else: ""}</span>
            <button
              id={"managed-release-#{binding.id}"}
              type="button"
              class="btn btn-xs btn-outline"
              phx-click="managed_release_domain"
              phx-value-binding-id={binding.id}
              data-confirm="Освободить этот адрес? Витрина может перестать открываться."
            >Освободить</button>
            <button
              :if={binding.state in ~w(reserved waiting_dns error)}
              class="btn btn-xs"
              phx-click="managed_prepare_domain"
              phx-value-binding-id={binding.id}
            >Подготовить</button>
            <button
              :if={binding.purpose == "site" and binding.state == "connected" and !binding.primary}
              class="btn btn-xs"
              phx-click="managed_confirm_browser"
              phx-value-binding-id={binding.id}
              data-confirm="Вы открыли новый адрес в браузере и проверили витрину, вход и корзину?"
            >Подтвердить браузер</button>
            <button
              :if={
                binding.purpose == "site" and binding.state == "connected" and !binding.primary and
                  binding.observed_records["browser_verification"]
              }
              class="btn btn-xs btn-primary"
              phx-click="managed_activate_domain"
              phx-value-binding-id={binding.id}
            >Сделать основным</button>
          </div>
        </div>
        <div
          :if={@node_placement}
          id="managed-delete"
          class="rounded-lg border border-error/40 p-3 space-y-2 text-sm"
        >
          <h3 class="font-semibold">Удалить установку</h3>
          <p>
            Сначала остановите франшизу и освободите все адреса выше. После подтверждения нода удалит её контейнеры, тома, локальные файлы и маршруты. Внешние резервные копии сохраняются.
          </p>
          <p>ID франшизы: <code>{@instance.id}</code></p>
          <.form
            for={@delete_form}
            id="managed-delete-form"
            phx-submit="managed_delete"
            class="flex flex-wrap items-end gap-2"
          >
            <.input
              field={@delete_form[:confirm_instance_id]}
              label="Введите ID франшизы"
            />
            <button
              type="submit"
              class="btn btn-error btn-sm"
              disabled={
                @domain_bindings != [] || @instance.desired_state != "stopped" ||
                  @node_placement.observed_state != "stopped"
              }
              data-confirm="Удалить данные только этой франшизы с ноды?"
            >
              Удалить установку
            </button>
          </.form>
        </div>
        <.form
          for={%{}}
          as={:instance}
          phx-submit="rename_managed"
          class="flex flex-wrap items-end gap-2"
        >
          <.input
            name="instance[name]"
            value={@instance.name}
            label="Название франшизы"
            required
          />
          <button class="btn btn-sm">Переименовать</button>
        </.form>
        <h3 class="font-semibold">История операций</h3>
        <p :for={operation <- @node_operations} class="text-sm">
          {datetime(operation.inserted_at)} · {operation.action} · {operation.status} · {operation.result[
            "reason"
          ] || operation.result["message"]}
        </p>
      </section>

      <div
        :if={@instance.transport != "node" and Maintenance.active?(@instance)}
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

      <div
        :if={@instance.transport != "node" and @instance.stopped_at}
        id="instance-stopped"
        class="alert alert-info"
      >
        <.icon name="hero-pause-circle" class="size-5" />
        <span>
          Сайт выключен по плану {datetime(@instance.stopped_at)}. Пока его не включат,
          недоступность не считается ошибкой и уведомления не приходят.
        </span>
      </div>

      <div
        :if={@instance.transport != "node"}
        id="instance-overview"
        class="rounded-xl border border-base-300 bg-base-100 p-4 sm:p-5"
      >
        <div class="flex flex-wrap items-center justify-between gap-4">
          <div class="flex flex-wrap gap-6" id="instance-endpoints">
            <.open_link
              id="detail-server-open"
              host={@instance.hosts["api"]}
              kind="server"
              instance_name={@instance.name}
            />
            <.open_link
              id="detail-client-open"
              host={@instance.hosts["site"]}
              kind="client"
              instance_name={@instance.name}
            />
          </div>
          <div id="detail-version"><.site_version instance={@instance} /></div>
        </div>
      </div>

      <div :if={@instance.transport != "node"} id="instance-modules" class="space-y-3">
        <.module_panel
          id="errors"
          title="Проблемы"
          hint={
            if(errors_count(@instance, @health) > 0,
              do: "Требуют внимания: #{errors_count(@instance, @health)}",
              else: "Активных проблем нет"
            )
          }
          icon="hero-exclamation-triangle"
          open={MapSet.member?(@open_modules, "errors")}
        >
          <div id="tab-errors-panel" class="space-y-4">
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
                    <tr
                      :for={order <- CrmAlerts.problems(@instance)}
                      id={"crm-order-#{order["id"]}"}
                    >
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
                      <td class="text-xs text-base-content/70 max-w-80 break-words">
                        {order["error"]}
                      </td>
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
        </.module_panel>
        <.module_panel
          id="updates"
          title="Обновления"
          hint={
            if(Images.up_to_date?(@instance) == false,
              do: "Доступно обновление",
              else: "Версия и управление обновлением"
            )
          }
          icon="hero-arrow-path"
          open={MapSet.member?(@open_modules, "updates")}
        >
          <div id="tab-updates-panel" class="space-y-4">
            <div class="flex flex-wrap items-center justify-between gap-4">
              <.site_version instance={@instance} />
              <div id="instance-actions" class="space-y-2">
                <div id="latest-release" class="text-sm">
                  Последняя стабильная:
                  <strong>{if @latest_release, do: @latest_release.version, else: "—"}</strong>
                  <a
                    :if={@latest_release}
                    href={"https://github.com/ShafranovKirill/delivest/releases/tag/v#{@latest_release.version}"}
                    target="_blank"
                    rel="noopener noreferrer"
                    class="link ml-2"
                  >Что изменилось</a>
                  <span :if={@latest_loading?} class="loading loading-spinner loading-xs"></span>
                  <button
                    :if={@latest_error?}
                    id="refresh-latest"
                    type="button"
                    class="btn btn-link btn-xs"
                    phx-click="refresh_latest"
                  >Повторить проверку</button>
                  <p :if={@latest_error?} class="text-warning">
                    Не удалось проверить релизы GitHub.
                  </p>
                </div>
                <.form for={@release_form} id="release-form" phx-submit="install_release">
                  <button
                    id="instance-update"
                    type="submit"
                    class="btn btn-primary btn-sm"
                    disabled={
                      is_nil(@latest_release) || @latest_loading? ||
                        !Releases.newer?(
                          @latest_release.version,
                          confirmed_release(@instance)["version"]
                        ) ||
                        !@instance.online || busy?(@commands) ||
                        "release_manifest_v1" not in @instance.capabilities
                    }
                    data-confirm="Обновить сайт до последней стабильной версии?"
                  >
                    <.icon name="hero-arrow-path" class="size-4" /> {cond do
                      @latest_release -> "Обновить до #{@latest_release.version}"
                      @latest_error? -> "Обновление недоступно"
                      true -> "Проверяем версию"
                    end}
                  </button>
                </.form>
                <p
                  :if={
                    @latest_release &&
                      !Releases.newer?(
                        @latest_release.version,
                        confirmed_release(@instance)["version"]
                      )
                  }
                  id="release-current"
                  class="text-sm text-success"
                >
                  {if @latest_release.version == confirmed_release(@instance)["version"],
                    do: "Установлена актуальная версия.",
                    else: "Установленная версия новее последней стабильной."}
                </p>
                <p
                  :if={"release_manifest_v1" not in @instance.capabilities}
                  id="agent-upgrade-required"
                  class="text-sm text-warning"
                >
                  Сначала обновите агент для установки выбранной версии.
                </p>
              </div>
            </div>
            <div id="release-state" class="rounded-box bg-base-200 p-3 text-sm space-y-1">
              <p>
                Подтверждённая версия сайта:
                <strong>{confirmed_release(@instance)["version"] || "—"}</strong>
              </p>
              <p>
                Digest server:
                <code>{get_in(confirmed_release(@instance), ["digest", "server"]) || "—"}</code>
              </p>
              <p>
                Digest client:
                <code>{get_in(confirmed_release(@instance), ["digest", "client"]) || "—"}</code>
              </p>
              <p>
                Агент: {get_in(@instance.status || %{}, ["agent", "version"]) ||
                  @instance.agent_version || "—"} · digest
                <code>{get_in(@instance.status || %{}, ["agent", "digest"]) || "—"}</code>
              </p>
              <p :if={last_attempt(@instance) != %{}}>
                Последняя попытка: {last_attempt(@instance)["version"] || "—"} · {last_attempt(
                  @instance
                )["status"] || "выполняется"} · {last_attempt(@instance)["error"]}
              </p>
              <p :if={@last_update_command} id="last-update-command">
                Цель {get_in(@last_update_command.args, ["release", "version"]) || "—"} · команда {@last_update_command.id} · {@last_update_command.status} · {@last_update_command.output}
              </p>
            </div>
          </div>
        </.module_panel>
        <.module_panel
          id="state"
          title="Мониторинг"
          hint="Доступность, нагрузка и статистика приложения"
          icon="hero-chart-bar"
          open={MapSet.member?(@open_modules, "state")}
        >
          <div id="tab-state-panel" class="space-y-4">
            <section id="uptime" class="card bg-base-100 border border-base-300">
              <div class="card-body p-4 gap-3">
                <h2 class="font-bold">Доступность</h2>
                <div class="grid grid-cols-3 gap-2">
                  <div :for={period <- Downtime.periods()} class="rounded-box bg-base-200 p-3">
                    <div class="text-xs text-base-content/60">{Downtime.format_period(period)}</div>
                    <div class={[
                      "text-xl font-bold tabular-nums",
                      uptime_class(@uptime[period].uptime)
                    ]}>
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
                    <div :if={@load.cpus} class="text-xs text-base-content/60">
                      {@load.cpus} ядер
                    </div>
                  </div>
                  <div class="rounded-box bg-base-200 p-3">
                    <div class="text-xs text-base-content/60">RAM хоста</div>
                    <div class="text-xl font-bold tabular-nums">
                      {(@load.memory && percent(@load.memory)) || "—"}
                    </div>
                    <div
                      :if={@load.memory_total_kb}
                      class="text-xs text-base-content/60 tabular-nums"
                    >
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
          </div>
        </.module_panel>
        <.module_panel
          id="backups"
          title="Резервные копии"
          hint={"Сохранено: #{length(@backups)} · создание и восстановление"}
          icon="hero-circle-stack"
          open={MapSet.member?(@open_modules, "backups")}
        >
          <div id="tab-backups-panel" class="space-y-4">
            <section id="full-snapshot" class="card bg-base-100 border border-base-300">
              <div class="card-body p-4 gap-3">
                <div class="flex flex-wrap items-start justify-between gap-2">
                  <div>
                    <h2 class="font-bold">Полный слепок франшизы</h2>
                    <p class="text-xs text-base-content/60">
                      База и все файлы. Создаётся ежедневно в 00:30 UTC (03:30 МСК); во время создания сайт останавливается.
                      Хранится последняя проверенная копия. Архив содержит приватные файлы и ключи интеграций.
                    </p>
                  </div>
                  <button
                    id="snapshot-now"
                    type="button"
                    class="btn btn-sm"
                    phx-click="full_snapshot"
                    disabled={
                      !@instance.online || busy?(@commands) || !snapshots_supported?(@instance) ||
                        (@snapshot_current && @snapshot_current.status == "pending")
                    }
                    data-confirm="Создать полный слепок сейчас? На время копирования сайт будет остановлен."
                  >
                    Создать сейчас
                  </button>
                </div>
                <p :if={!snapshots_supported?(@instance)} class="text-sm text-warning">
                  Агент этого экземпляра не поддерживает полный слепок.
                </p>
                <p
                  :if={@snapshot_current && @snapshot_current.status == "pending"}
                  id="snapshot-pending"
                  class="text-sm text-info"
                >
                  Новый слепок создаётся. Последний готовый доступен ниже.
                </p>
                <p
                  :if={@snapshot_current && @snapshot_current.status == "error"}
                  id="snapshot-error"
                  class="text-sm text-error"
                >
                  Последняя попытка не удалась: {@snapshot_current.error}
                </p>
                <p
                  :if={snapshot_stale?(@snapshot_latest)}
                  id="snapshot-stale"
                  class="text-sm text-warning"
                >
                  Последнему готовому слепку больше суток.
                </p>
                <div
                  :if={@snapshot_latest}
                  id="snapshot-latest"
                  class="flex flex-wrap items-center gap-3 text-sm"
                >
                  <span>Готовый слепок: {datetime(@snapshot_latest.finished_at)}</span>
                  <span>{format_size(@snapshot_latest.size)}</span>
                  <span class="badge badge-success badge-sm">проверен</span>
                  <.link
                    id="snapshot-download"
                    href={~p"/backups/snapshots/#{@snapshot_latest.id}/download"}
                    class="btn btn-sm btn-outline"
                  >
                    <.icon name="hero-arrow-down-tray" class="size-4" /> Скачать
                  </.link>
                </div>
                <p :if={!@snapshot_latest} id="snapshot-empty" class="text-sm text-base-content/60">
                  Готового слепка пока нет.
                </p>
              </div>
            </section>
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
                          <span
                            :if={backup.verify_status == "error"}
                            class="badge badge-error badge-sm"
                          >
                            не читается
                          </span>
                          <span
                            :if={backup.offsite_at}
                            class="badge badge-ghost badge-sm"
                            title="Копия лежит во внешнем хранилище"
                          >
                            <.icon name="hero-cloud-arrow-up-micro" class="size-3" /> копия
                          </span>
                          <span
                            :if={backup.error}
                            class="block text-xs text-error whitespace-pre-wrap"
                          >
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
                              !@instance.online || busy?(@commands) ||
                                !backups_supported?(@instance)
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
        </.module_panel>
        <.module_panel
          id="logs"
          title="Диагностика"
          hint="Логи, контейнеры, проверки и вывод команд"
          icon="hero-command-line"
          open={MapSet.member?(@open_modules, "logs")}
        >
          <div id="tab-logs-panel" class="space-y-4">
            <details
              id="technical-details"
              class="rounded-xl border border-base-300 bg-base-100 p-4"
            >
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
                          <td class={
                            (container["state"] == "running" && "text-success") || "text-error"
                          }>
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
                          <td class="font-semibold">
                            {if kind == "api", do: "Server", else: "Client"}
                          </td>
                          <td><.check check={(@instance.status || %{})["checks"][kind]} /></td>
                          <td><.check check={@instance.external[kind]} /></td>
                          <td>
                            <% days =
                              cert_days((@instance.external[kind] || %{})["cert_expires_at"]) %>
                            <span :if={days} class={days < 14 && "text-warning"}>{days} дн.</span>
                            <span :if={!days} class="text-base-content/40">—</span>
                          </td>
                        </tr>
                      </tbody>
                    </table>
                    <p class="text-xs text-base-content/60">
                      Диск: {(disk_percent(@instance) && "#{disk_percent(@instance)}% занято") ||
                        "—"} ·
                      проверено снаружи {ago(@instance.checked_at)}
                    </p>
                  </div>
                </section>
              </div>
            </details>
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
              <div :if={@commands == []} class="text-sm text-base-content/60">
                Команд ещё не было
              </div>
              <details
                :for={command <- @commands}
                id={"command-#{command.id}"}
                class="rounded-box border border-base-300 bg-base-100"
                open={command.action == "logs" && command == hd(@commands)}
              >
                <summary class="flex flex-wrap items-center gap-3 p-3 cursor-pointer">
                  <span class="font-semibold">{action_label(command.action)}</span>
                  <span :if={command.args["service"]} class="text-xs">{command.args["service"]}</span>
                  <span :if={command.args["release"]} class="text-xs">цель {command.args["release"][
                    "version"
                  ]}</span>
                  <span class="font-mono text-xs text-base-content/60">{command.id}</span>
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
        </.module_panel>
        <.module_panel
          id="history"
          title="История"
          hint="Операции и окна обслуживания"
          icon="hero-clock"
          open={MapSet.member?(@open_modules, "history")}
        >
          <div id="tab-history-panel" class="space-y-4">
            <section class="rounded-xl border border-base-300 bg-base-100 p-4 space-y-3">
              <div class="flex flex-wrap items-center justify-between gap-3">
                <h2 class="font-semibold">Последние операции</h2>
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
              <p :if={@maintenance_windows == []} class="text-sm text-base-content/60">
                Пока не было
              </p>
              <div
                :for={window <- @maintenance_windows}
                id={"maintenance-window-#{window.id}"}
                class="border-t border-base-200 pt-2 text-sm"
              >
                {datetime(window.started_at)} — {datetime(window.ended_at || window.scheduled_end_at)}
                <span
                  :if={is_nil(window.ended_at) && Maintenance.active?(@instance)}
                  class="text-sky-700"
                >· идёт</span>
              </div>
            </section>
          </div>
        </.module_panel>
        <.module_panel
          id="settings"
          title="Настройки"
          hint="Контакты, подписка, доступы и управление"
          icon="hero-cog-6-tooth"
          open={MapSet.member?(@open_modules, "settings")}
        >
          <div id="tab-settings-panel" class="space-y-4">
            <section
              id="client-card"
              class="rounded-xl border border-base-300 bg-base-100 p-5 sm:p-6 space-y-5"
            >
              <div class="flex items-center justify-between gap-3">
                <h2 class="font-semibold">Клиент и подписка</h2>
                <button
                  :if={!@editing_client?}
                  id="edit-client"
                  type="button"
                  phx-click="edit_client"
                  class="text-sm text-base-content/60 hover:text-primary transition-colors"
                >Изменить</button>
              </div>
              <div :if={!@editing_client?} class="grid gap-6 sm:grid-cols-2 lg:grid-cols-3">
                <div :if={@instance.transport != "node"} id="client-payment" class="space-y-2">
                  <div class="text-xs text-base-content/50">Подписка</div>
                  <.payment_date date={@instance.payment_due_on} />
                </div>
                <div id="client-contact" class="space-y-2">
                  <div class="text-xs text-base-content/50">Телефон клиента</div>
                  <p class="text-sm">{@instance.contact_phone || "Не указан"}</p>
                  <div class="flex flex-col items-start gap-1">
                    <a
                      :for={link <- String.split(@instance.social_links || "", ~r/\s+/, trim: true)}
                      href={link}
                      target="_blank"
                      rel="noopener noreferrer"
                      class="max-w-full break-all text-sm text-primary hover:underline"
                    >{link} ↗</a>
                  </div>
                </div>
                <div id="admin-credentials" class="space-y-2">
                  <div class="text-xs text-base-content/50">Доступ в админку</div>
                  <p class="text-sm">{@instance.admin_login || "Логин не указан"}</p>
                  <div
                    :if={@instance.admin_password_encrypted}
                    class="flex flex-wrap items-center gap-3"
                  >
                    <span id="saved-password" class="break-all font-mono text-sm">{@revealed_password ||
                      "••••••••"}</span>
                    <button
                      id="toggle-password"
                      type="button"
                      phx-click={if @revealed_password, do: "hide_password", else: "reveal_password"}
                      class="text-xs text-base-content/50 hover:text-primary"
                    >{if @revealed_password, do: "Скрыть", else: "Показать"}</button>
                  </div>
                  <p :if={!@instance.admin_password_encrypted} class="text-sm text-base-content/40">
                    {if @instance.transport == "node",
                      do: "Ожидаем безопасную передачу доступа от ноды",
                      else: "Пароль не сохранён"}
                  </p>
                </div>
              </div>
              <.form
                :if={@editing_client?}
                for={@client_form}
                id="client-form"
                phx-submit="save_client"
                class="grid gap-x-6 gap-y-2 sm:grid-cols-2"
              >
                <.input
                  field={@client_form[:contact_phone]}
                  type="tel"
                  label="Телефон клиента"
                />
                <.input
                  :if={@instance.transport != "node"}
                  field={@client_form[:payment_due_on]}
                  type="date"
                  label="Дата оплаты / оплачено до"
                />
                <div class="sm:col-span-2">
                  <.input
                    field={@client_form[:social_links]}
                    type="textarea"
                    label="Ссылки на соцсети"
                    placeholder="https://t.me/username"
                  />
                </div>
                <.input
                  :if={@instance.transport != "node"}
                  field={@client_form[:admin_login]}
                  type="text"
                  label="Логин от админки"
                  autocomplete="off"
                />
                <.input
                  :if={@instance.transport != "node"}
                  field={@client_form[:admin_password]}
                  type="password"
                  label="Новый пароль от админки"
                  value=""
                  autocomplete="new-password"
                  placeholder="Оставьте пустым, чтобы сохранить текущий"
                />
                <p
                  :if={@instance.transport != "node"}
                  class="sm:col-span-2 text-xs text-base-content/50"
                >
                  Одно уведомление в Telegram в день оплаты, с 09:00 по Москве. {if !Bastion.Telegram.configured?(),
                    do: "Telegram пока не настроен."}
                </p>
                <div class="sm:col-span-2 flex gap-3 pt-2">
                  <button
                    id="save-client"
                    type="submit"
                    phx-disable-with="Сохраняю…"
                    class="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content transition-opacity hover:opacity-85"
                  >Сохранить</button>
                  <button
                    id="cancel-client"
                    type="button"
                    phx-click="cancel_client"
                    class="px-3 py-2 text-sm text-base-content/60 hover:text-base-content"
                  >Отмена</button>
                </div>
              </.form>
            </section>

            <div class="flex flex-wrap gap-2">
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
                      !@instance.online || busy?(@commands) || !env_supported?(@instance) ||
                        @env_request
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
                      <span
                        :if={Images.agent_outdated?(@instance)}
                        class="badge badge-info badge-xs ml-1"
                      >
                        есть новее
                      </span>
                    </p>
                    <p class="text-xs text-base-content/60">
                      Агент скачает свой новый образ и пересоздаст себя, заодно подхватит новый .env.
                      Сайт при этом работает, бастион на несколько секунд потеряет связь с агентом.
                    </p>
                  </div>
                  <.form
                    :if={
                      "agent_update" in @instance.actions and
                        "release_manifest_v1" in @instance.capabilities
                    }
                    for={@agent_release_form}
                    id="agent-release-form"
                    phx-submit="install_agent_release"
                    class="flex flex-wrap items-end gap-2"
                  >
                    <button
                      id="agent-update"
                      type="submit"
                      class="btn btn-sm"
                      disabled={
                        is_nil(@latest_release) || @latest_loading? ||
                          !Releases.newer?(
                            @latest_release.version,
                            get_in(@instance.status || %{}, ["agent", "version"]) ||
                              @instance.agent_version
                          ) ||
                          !@instance.online || busy?(@commands)
                      }
                      data-confirm="Установить агента из последнего стабильного релиза?"
                    >
                      <.icon name="hero-arrow-path" class="size-4" /> {cond do
                        @latest_release -> "Обновить агента до #{@latest_release.version}"
                        @latest_error? -> "Обновление недоступно"
                        true -> "Проверяем версию"
                      end}
                    </button>
                  </.form>
                  <p :if={@latest_error?} class="text-sm text-warning">
                    Не удалось проверить релизы.
                    <button type="button" phx-click="refresh_latest" class="btn btn-link btn-xs">Повторить</button>
                  </p>
                  <button
                    :if={
                      "agent_update" in @instance.actions and
                        "release_manifest_v1" not in @instance.capabilities
                    }
                    id="agent-update"
                    type="button"
                    class="btn btn-sm"
                    phx-click="command"
                    phx-value-action="agent_update"
                    disabled={!@instance.online || busy?(@commands)}
                    data-confirm="Обновить агент до версии с поддержкой выбора релиза?"
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
            <div
              id="danger-zone"
              class="mt-6 rounded-xl border border-error/30 bg-error/5 p-4 space-y-3"
            >
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
        </.module_panel>
      </div>
    </Layouts.app>
    """
  end
end
