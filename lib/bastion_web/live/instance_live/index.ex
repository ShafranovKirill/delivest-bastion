defmodule BastionWeb.InstanceLive.Index do
  use BastionWeb, :live_view

  import BastionWeb.InstanceLive.Components

  alias Bastion.{Downtime, Health, Instances}
  alias BastionWeb.Presence

  @tick :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Instances.subscribe()
      Phoenix.PubSub.subscribe(Bastion.PubSub, Presence.topic())
      :timer.send_interval(@tick, :tick)
    end

    {:ok, socket |> assign(page_title: "Экземпляры") |> load()}
  end

  @impl true
  def handle_info({event, _record}, socket) when event in [:instance_updated, :instance_deleted],
    do: {:noreply, load(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load(socket)}

  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    instances = Instances.list_instances()
    health = Map.new(instances, &{&1.id, Health.evaluate(&1)})
    uptime = Map.new(instances, &{&1.id, Downtime.summary(&1)})
    assign(socket, instances: instances, health: health, uptime: uptime)
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
          </p>
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
              <td class="font-mono text-xs">{revision(instance, "server") || "—"}</td>
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
end
