defmodule BastionWeb.InstanceLive.Index do
  use BastionWeb, :live_view

  import BastionWeb.InstanceLive.Components

  alias Bastion.{Downtime, Health, Images, Instances, Rollout}
  alias BastionWeb.Presence

  @tick :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Instances.subscribe()
      Phoenix.PubSub.subscribe(Bastion.PubSub, Presence.topic())
      :timer.send_interval(@tick, :tick)
    end

    {:ok, socket |> assign(page_title: "Экземпляры", rollout: Rollout.state()) |> load()}
  end

  @impl true
  def handle_event("rollout", _params, socket) do
    socket =
      case Rollout.start(socket.assigns.current_admin) do
        :ok ->
          put_flash(socket, :info, "Сайты обновляются по очереди")

        {:error, :already_running} ->
          put_flash(socket, :error, "Обновление уже идёт")

        {:error, :nothing_to_update} ->
          put_flash(socket, :info, "Все сайты на связи уже обновлены")
      end

    {:noreply, assign(socket, rollout: Rollout.state())}
  end

  def handle_event("rollout_cancel", _params, socket) do
    :ok = Rollout.cancel(socket.assigns.current_admin)
    {:noreply, assign(socket, rollout: Rollout.state())}
  end

  def handle_event("check_images", _params, socket) do
    Images.refresh()
    {:noreply, put_flash(socket, :info, "Проверяю новые образы в реестре")}
  end

  @impl true
  def handle_info({event, _record}, socket) when event in [:instance_updated, :instance_deleted],
    do: {:noreply, load(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load(socket)}

  def handle_info({:rollout_updated, rollout}, socket),
    do: {:noreply, socket |> assign(rollout: rollout) |> load()}

  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    instances = Instances.list_instances()
    health = Map.new(instances, &{&1.id, Health.evaluate(&1)})
    uptime = Map.new(instances, &{&1.id, Downtime.summary(&1)})

    assign(socket,
      instances: instances,
      health: health,
      uptime: uptime,
      outdated: Enum.count(instances, &(Images.outdated(&1) != []))
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 class="text-2xl font-bold">Экземпляры</h1>
          <p class="text-sm text-base-content/60">
            {length(@instances)} всего · {Enum.count(@instances, & &1.online)} на связи
            <span :if={@outdated > 0}> · {@outdated} можно обновить</span>
          </p>
        </div>
        <div :if={@instances != []} class="flex flex-wrap gap-2">
          <button
            id="check-images"
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="check_images"
          >
            <.icon name="hero-magnifying-glass" class="size-4" /> Проверить образы
          </button>
          <button
            :if={!Rollout.running?(@rollout)}
            id="rollout-start"
            type="button"
            class="btn btn-primary btn-sm"
            phx-click="rollout"
            data-confirm="Обновить по очереди все сайты на связи, у которых есть новые образы? Каждый сначала сделает бэкап, следующий начнётся только когда предыдущий снова заработает, а первая ошибка остановит остальные."
          >
            <.icon name="hero-queue-list" class="size-4" /> Обновить по очереди
          </button>
          <button
            :if={Rollout.running?(@rollout)}
            id="rollout-cancel"
            type="button"
            class="btn btn-sm btn-error btn-outline"
            phx-click="rollout_cancel"
          >
            Остановить очередь
          </button>
        </div>
      </div>

      <div
        :if={@rollout.status != :idle}
        id="rollout"
        class={[
          "alert text-sm",
          @rollout.status == :running && "alert-info",
          @rollout.status == :done && "alert-success",
          @rollout.status in [:failed, :cancelled] && "alert-warning"
        ]}
      >
        <span :if={@rollout.status == :running} class="loading loading-spinner loading-sm"></span>
        <div>
          <div class="font-semibold">{rollout_title(@rollout)}</div>
          <div class="text-xs">
            Готово: {length(@rollout.done)}<span :if={@rollout.queue != []}>, в очереди: {length(
              @rollout.queue
            )}</span>
          </div>
          <div :if={@rollout.error} class="text-xs whitespace-pre-wrap">{@rollout.error}</div>
        </div>
      </div>

      <div :if={@instances == []} id="instances-empty" class="py-16 text-center text-base-content/60">
        Пока ни один агент не подключился. Укажите в .env экземпляра BASTION_URL и BASTION_TOKEN.
      </div>

      <div :if={@instances != []} class="overflow-x-auto rounded-box border border-base-300">
        <table id="instances" class="table">
          <thead>
            <tr>
              <th>Экземпляр</th>
              <th>Состояние</th>
              <th>API</th>
              <th>Сайт</th>
              <th>Версия</th>
              <th>Аптайм 7 дн</th>
              <th>Диск</th>
              <th>Связь</th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={instance <- @instances}
              id={"instance-#{instance.id}"}
              class="hover:bg-base-200 cursor-pointer"
              phx-click={JS.navigate(~p"/instances/#{instance.id}")}
            >
              <td>
                <div class="flex items-center gap-2">
                  <.online_dot online={instance.online} />
                  <span class="font-semibold">{instance.name}</span>
                </div>
                <div class="text-xs text-base-content/60">{instance.hosts["site"]}</div>
              </td>
              <td>
                <.health_badge level={@health[instance.id].level} />
                <span
                  :for={key <- instance.site_alerts |> Map.keys() |> Enum.sort()}
                  class="badge badge-error badge-sm ml-1 whitespace-nowrap"
                >
                  {Bastion.SiteAlerts.label(key)}
                </span>
                <span
                  :if={Bastion.CrmAlerts.problems(instance) != []}
                  class="badge badge-error badge-sm ml-1"
                  title="Заказы не дошли до CRM"
                >
                  CRM: {length(Bastion.CrmAlerts.problems(instance))}
                </span>
                <div
                  :for={problem <- Enum.take(@health[instance.id].problems, 2)}
                  class="text-xs text-base-content/60 max-w-64 truncate"
                  title={problem}
                >
                  {problem}
                </div>
              </td>
              <td><.check check={instance.external["api"]} /></td>
              <td><.check check={instance.external["site"]} /></td>
              <td class="font-mono text-xs">
                {revision(instance, "server") || "—"}
                <span
                  :if={Images.outdated(instance) != []}
                  class="badge badge-info badge-xs ml-1"
                  title={"Есть новые образы: " <> Enum.join(Images.outdated(instance), ", ")}
                >
                  новее
                </span>
                <span
                  :if={Images.agent_outdated?(instance)}
                  class="badge badge-ghost badge-xs ml-1"
                  title="Агент отстаёт от последнего образа"
                >
                  агент
                </span>
              </td>
              <td class={["tabular-nums", uptime_class(@uptime[instance.id].week.uptime)]}>
                {format_uptime(@uptime[instance.id].week.uptime)}
              </td>
              <td>{(disk_percent(instance) && "#{disk_percent(instance)}%") || "—"}</td>
              <td class="text-xs whitespace-nowrap">{ago(instance.last_seen_at)}</td>
            </tr>
          </tbody>
        </table>
      </div>
    </Layouts.app>
    """
  end

  defp rollout_title(%{status: :running} = rollout) do
    current = rollout.current && Instances.get_instance(rollout.current)

    phase = if rollout.phase == :verify, do: "ждём, когда ответит", else: "обновляется"
    "Обновление по очереди: #{(current && current.name) || "—"} #{phase}"
  end

  defp rollout_title(%{status: :done}), do: "Обновление по очереди закончено"
  defp rollout_title(%{status: :failed}), do: "Обновление по очереди остановлено"
  defp rollout_title(%{status: :cancelled}), do: "Обновление по очереди отменено"
end
