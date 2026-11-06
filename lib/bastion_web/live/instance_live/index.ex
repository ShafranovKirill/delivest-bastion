defmodule BastionWeb.InstanceLive.Index do
  use BastionWeb, :live_view

  import BastionWeb.InstanceLive.Components

  alias Bastion.{Health, Images, Instances, Rollout}
  alias BastionWeb.Presence

  @tick :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Instances.subscribe()
      Phoenix.PubSub.subscribe(Bastion.PubSub, Presence.topic())
      :timer.send_interval(@tick, :tick)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Франшизы",
       rollout: Rollout.state(),
       checking_images?: false,
       image_result: nil
     )
     |> load()}
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
    if socket.assigns.checking_images? do
      {:noreply, socket}
    else
      {:noreply,
       socket
       |> assign(checking_images?: true, image_result: nil)
       |> start_async(:check_images, fn -> Images.check() end)}
    end
  end

  @impl true
  def handle_async(:check_images, {:ok, result}, socket) do
    message = "Проверено образов: #{result.checked}. Ошибок: #{result.errors}."
    {:noreply, socket |> assign(checking_images?: false, image_result: message) |> load()}
  end

  def handle_async(:check_images, {:exit, _reason}, socket) do
    {:noreply,
     assign(socket,
       checking_images?: false,
       image_result: "Не удалось проверить обновления. Попробуйте ещё раз."
     )}
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
    instances = Enum.sort_by(instances, &health_rank(health[&1.id].level))

    socket
    |> assign(instance_count: length(instances), health: health)
    |> stream(:instances, instances, reset: true, dom_id: &"instance-#{&1.id}")
  end

  defp health_rank(:down), do: 0
  defp health_rank(:warning), do: 1
  defp health_rank(:offline), do: 2
  defp health_rank(:unknown), do: 3
  defp health_rank(:stopped), do: 4
  defp health_rank(:maintenance), do: 4
  defp health_rank(:ok), do: 5

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <div class="flex flex-wrap items-center justify-between gap-3">
        <div>
          <h1 class="text-2xl font-bold">Франшизы</h1>
          <p class="text-sm text-base-content/60">
            Всего {@instance_count}
          </p>
        </div>
        <div :if={@instance_count > 0} class="flex flex-wrap gap-2">
          <button
            id="check-images"
            type="button"
            class="btn btn-ghost btn-sm"
            phx-click="check_images"
            disabled={@checking_images?}
          >
            <.icon name="hero-magnifying-glass" class="size-4" /> {if @checking_images?,
              do: "Проверяем…",
              else: "Проверить обновления"}
          </button>
        </div>
      </div>

      <p
        :if={@image_result}
        id="image-check-result"
        role="status"
        class="text-sm text-base-content/60"
      >
        {@image_result}
      </p>

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

      <div
        :if={@instance_count == 0}
        id="instances-empty"
        class="py-16 text-center text-base-content/60"
      >
        Пока ни одна франшиза не подключена. Укажите в .env её агента BASTION_URL и BASTION_TOKEN.
      </div>

      <div
        :if={@instance_count > 0}
        class="rounded-xl border border-base-300 bg-base-100"
      >
        <table id="instances" class="block w-full border-collapse text-left sm:table">
          <thead class="hidden sm:table-header-group">
            <tr>
              <th class="px-5 py-3 text-xs font-medium text-base-content/50">Франшиза</th>
              <th class="px-5 py-3 text-xs font-medium text-base-content/50">Подписка</th>
              <th class="px-5 py-3 text-xs font-medium text-base-content/50">Версия сайта</th>
              <th class="px-5 py-3 text-xs font-medium text-base-content/50">Админка</th>
              <th class="px-5 py-3 text-xs font-medium text-base-content/50">Сайт</th>
            </tr>
          </thead>
          <tbody id="instance-rows" phx-update="stream" class="block sm:table-row-group">
            <tr
              :for={{id, instance} <- @streams.instances}
              id={id}
              class="grid grid-cols-2 gap-x-3 gap-y-3 border-b border-base-300 p-4 last:border-b-0 transition-colors hover:bg-base-200/50 sm:table-row sm:p-0"
            >
              <td class="col-span-2 min-w-0 p-0 sm:table-cell sm:px-5 sm:py-4">
                <.link
                  navigate={~p"/instances/#{instance.id}"}
                  class="block break-words font-semibold leading-snug hover:underline focus-visible:underline sm:inline"
                >
                  {instance.name}
                </.link>
                <div
                  :if={@health[instance.id].level != :ok}
                  id={"problem-#{instance.id}"}
                  class="mt-1 text-xs"
                >
                  <.health_badge level={@health[instance.id].level} />
                </div>
              </td>
              <td class="p-0 sm:table-cell sm:px-5 sm:py-4" id={"subscription-#{instance.id}"}>
                <div class="mb-1 text-xs text-base-content/50 sm:hidden">Подписка</div>
                <.payment_date date={instance.payment_due_on} />
              </td>
              <td class="p-0 sm:table-cell sm:px-5 sm:py-4" id={"version-#{instance.id}"}>
                <div class="mb-1 text-xs text-base-content/50 sm:hidden">Версия сайта</div>
                <.site_version instance={instance} />
              </td>
              <td class="min-w-0 border-t border-base-200 p-0 pt-3 sm:table-cell sm:border-0 sm:px-5 sm:py-4">
                <.open_link
                  id={"server-open-#{instance.id}"}
                  host={instance.hosts["api"]}
                  kind="server"
                  instance_name={instance.name}
                />
              </td>
              <td class="min-w-0 border-t border-base-200 p-0 pt-3 sm:table-cell sm:border-0 sm:px-5 sm:py-4">
                <.open_link
                  id={"client-open-#{instance.id}"}
                  host={instance.hosts["site"]}
                  kind="client"
                  instance_name={instance.name}
                />
              </td>
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
