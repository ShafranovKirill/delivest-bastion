defmodule BastionWeb.InstanceLive.Index do
  use BastionWeb, :live_view

  import BastionWeb.InstanceLive.Components

  alias Bastion.{Health, Images, Instances, ManagedInstances, ManagedRollout, Nodes, Rollout}
  alias BastionWeb.Presence

  @tick :timer.seconds(15)

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Instances.subscribe()
      Nodes.subscribe()
      Phoenix.PubSub.subscribe(Bastion.PubSub, Presence.topic())
      :timer.send_interval(@tick, :tick)
    end

    {:ok,
     socket
     |> assign(
       page_title: "Франшизы",
       search: "",
       rollout: Rollout.state(),
       managed_rollout: ManagedRollout.current(),
       checking_images?: false,
       image_result: nil,
       create_form: new_create_form()
     )
     |> load()}
  end

  @impl true
  def handle_event("search", %{"search" => query}, socket),
    do: {:noreply, socket |> assign(search: query) |> load()}

  def handle_event("create_managed", %{"franchise" => attrs}, socket) do
    case ManagedInstances.create(attrs, socket.assigns.current_admin) do
      {:ok, operation, proof} ->
        message =
          if proof,
            do: "Ожидаем DNS. TXT _delivest-verification.#{attrs["site_hostname"]}: #{proof}",
            else: "Создание запущено. Проверьте ход операции в карточке."

        {:noreply,
         socket
         |> put_flash(:info, message)
         |> push_navigate(to: ~p"/instances/#{operation.instance_id}")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Не удалось зарезервировать франшизу: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("rollout", _params, socket),
    do: {:noreply, put_flash(socket, :error, "Массовое обновление недоступно на этом экране")}

  def handle_event("rollout_cancel", _params, socket) do
    :ok = Rollout.cancel(socket.assigns.current_admin)
    {:noreply, assign(socket, rollout: Rollout.state())}
  end

  def handle_event("managed_rollout", %{"managed_rollout" => attrs}, socket) do
    ids = Map.get(attrs, "instance_ids", [])

    result =
      case attrs["scope"] do
        "all" ->
          ManagedRollout.start([], attrs["canary_id"], socket.assigns.current_admin)

        "selected" when ids != [] ->
          ManagedRollout.start(ids, attrs["canary_id"], socket.assigns.current_admin)

        _ ->
          {:error, :empty_selection}
      end

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Обновление запущено") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Не удалось запустить: #{inspect(reason)}")}
    end
  end

  def handle_event("managed_rollout_resume", %{"id" => id}, socket) do
    case ManagedRollout.resume(id, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Очередь продолжена") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Не удалось продолжить: #{inspect(reason)}")}
    end
  end

  def handle_event("managed_rollout_pause", %{"id" => id}, socket) do
    case ManagedRollout.pause(id, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply,
         socket |> put_flash(:info, "Выдача следующих заданий приостановлена") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Не удалось приостановить: #{inspect(reason)}")}
    end
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

  def handle_info(:nodes_updated, socket), do: {:noreply, load(socket)}

  def handle_info(%Phoenix.Socket.Broadcast{event: "presence_diff"}, socket),
    do: {:noreply, load(socket)}

  def handle_info({:rollout_updated, rollout}, socket),
    do: {:noreply, socket |> assign(rollout: rollout) |> load()}

  def handle_info(:tick, socket), do: {:noreply, load(socket)}
  def handle_info(_message, socket), do: {:noreply, socket}

  defp load(socket) do
    instances = Instances.list_instances()
    placements = Nodes.active_placements()
    query = socket.assigns.search |> String.trim() |> String.downcase()

    instances =
      Enum.filter(instances, fn instance ->
        query == "" or
          String.contains?(String.downcase(instance.name), query) or
          Enum.any?(
            Map.values(instance.hosts || %{}),
            &(is_binary(&1) and String.contains?(String.downcase(&1), query))
          )
      end)

    health = Map.new(instances, &{&1.id, Health.evaluate(&1)})
    instances = Enum.sort_by(instances, &health_rank(health[&1.id].level))

    socket
    |> assign(
      instance_count: length(instances),
      health: health,
      placements: placements,
      ready_nodes: Enum.filter(Nodes.list_nodes(), &(Nodes.ready?(&1) and not &1.maintenance)),
      managed_instances: Enum.filter(instances, &(&1.transport == "node")),
      managed_rollout: ManagedRollout.current()
    )
    |> stream(:instances, instances, reset: true, dom_id: &"instance-#{&1.id}")
  end

  defp new_create_form do
    to_form(
      %{
        "instance_id" => Ecto.UUID.generate(),
        "name" => "",
        "short_name" => "",
        "site_hostname" => "",
        "dns_mode" => "regru",
        "zone" => "delivest.ru",
        "node_id" => ""
      },
      as: :franchise
    )
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
      <section id="managed-create" class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-3">
        <h2 class="text-lg font-semibold">Создать франшизу</h2>
        <p class="text-sm text-base-content/60">
          Пустой адрес витрины создаст короткий поддомен delivest.ru. Для внешнего DNS потребуется TXT подтверждение.
        </p>
        <.form
          for={@create_form}
          id="managed-create-form"
          phx-submit="create_managed"
          class="grid gap-3 md:grid-cols-2"
        >
          <.input field={@create_form[:instance_id]} type="hidden" />
          <.input field={@create_form[:name]} label="Название" required />
          <.input field={@create_form[:short_name]} label="Короткое имя" required />
          <.input
            field={@create_form[:site_hostname]}
            label="Адрес витрины (необязательно)"
          />
          <.input
            field={@create_form[:dns_mode]}
            type="select"
            label="DNS витрины"
            options={[{"REG.RU", "regru"}, {"Внешний DNS", "external"}]}
          />
          <.input field={@create_form[:zone]} label="Управляемая DNS-зона" />
          <.input
            field={@create_form[:node_id]}
            type="select"
            label="Готовый сервер"
            options={Enum.map(@ready_nodes, &{&1.name, &1.id})}
            prompt="Выберите сервер"
            required
          />
          <button
            id="managed-create-submit"
            class="btn btn-primary md:col-span-2"
            disabled={@ready_nodes == []}
          >Создать</button>
        </.form>
        <p :if={@ready_nodes == []} class="text-sm text-warning">
          Нет готовой ноды с новым heartbeat и проверенной инфраструктурой.
        </p>
        <p :for={node <- @ready_nodes} class="text-xs text-base-content/60">
          {node.name}: метрики {if node.sampled_at,
            do: Calendar.strftime(node.sampled_at, "%d.%m %H:%M"),
            else: "отсутствуют"}; свободная память и диск требуют проверки перед размещением.
          <span :for={warning <- Bastion.Fleet.node_resources(node).warnings} class="text-warning">
            {warning}
          </span>
        </p>
      </section>
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

      <section
        id="managed-rollout"
        class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-3"
      >
        <h2 class="text-lg font-semibold">Обновить управляемые франшизы</h2>
        <.form
          for={to_form(%{}, as: :managed_rollout)}
          id="managed-rollout-form"
          phx-submit="managed_rollout"
          class="space-y-3"
        >
          <.input
            name="managed_rollout[scope]"
            type="select"
            value="all"
            label="Состав"
            options={[{"Все", "all"}, {"Выбранные", "selected"}]}
          />
          <.input
            name="managed_rollout[canary_id]"
            type="select"
            value=""
            label="Контрольная франшиза"
            options={Enum.map(@managed_instances, &{&1.name, &1.id})}
            prompt="Выберите франшизу"
            required
          />
          <div class="grid gap-2 sm:grid-cols-2">
            <label :for={instance <- @managed_instances} class="flex items-center gap-2 text-sm">
              <input
                type="checkbox"
                name="managed_rollout[instance_ids][]"
                value={instance.id}
                class="checkbox checkbox-sm"
              />
              {instance.name}
            </label>
          </div>
          <button
            class="btn btn-primary btn-sm"
            disabled={
              @managed_instances == [] or (@managed_rollout && @managed_rollout.status == "running")
            }
          >Начать обновление</button>
        </.form>
        <div :if={@managed_rollout} id="managed-rollout-progress" class="text-sm space-y-2">
          <p>
            Релиз {@managed_rollout.version}. Состояние {@managed_rollout.status}. Завершено {Enum.count(
              @managed_rollout.items,
              &(&1.status == "ok")
            )} из {length(@managed_rollout.items)}.
          </p>
          <p :if={@managed_rollout.paused_reason} class="text-warning">
            {@managed_rollout.paused_reason}
          </p>
          <button
            :if={@managed_rollout.status == "running"}
            phx-click="managed_rollout_pause"
            phx-value-id={@managed_rollout.id}
            class="btn btn-ghost btn-sm"
          >Приостановить выдачу следующих заданий</button>
          <button
            :if={@managed_rollout.status == "paused"}
            phx-click="managed_rollout_resume"
            phx-value-id={@managed_rollout.id}
            class="btn btn-warning btn-sm"
          >Продолжить очередь</button>
          <ul class="space-y-1">
            <li :for={item <- Enum.sort_by(@managed_rollout.items, & &1.position)}>
              {item.instance.name} — {item.status}<span :if={item.error}>: {item.error}</span>
            </li>
          </ul>
        </div>
      </section>

      <form id="instance-search" phx-change="search" class="max-w-sm">
        <.input
          name="search"
          value={@search}
          label="Поиск по названию и домену"
          phx-debounce="300"
        />
      </form>

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
        Франшизы пока не найдены.
      </div>

      <div
        :if={@instance_count > 0}
        class="rounded-xl border border-base-300 bg-base-100"
      >
        <table id="instances" class="block w-full border-collapse text-left sm:table">
          <thead class="hidden sm:table-header-group">
            <tr>
              <th class="px-5 py-3 text-xs font-medium text-base-content/50">Франшиза</th>
              <th class="px-5 py-3 text-xs font-medium text-base-content/50">Сервер</th>
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
                  :if={
                    @health[instance.id].level != :ok ||
                      get_in(instance.external || %{}, ["site", "ok"]) == false
                  }
                  id={"problem-#{instance.id}"}
                  class="mt-1 text-xs"
                >
                  <.site_status instance={instance} level={@health[instance.id].level} />
                </div>
              </td>
              <td class="p-0 sm:table-cell sm:px-5 sm:py-4">
                <.link
                  :if={@placements[instance.id]}
                  navigate={~p"/nodes/#{@placements[instance.id].node_id}"}
                  class="link text-sm"
                >{@placements[instance.id] && @placements[instance.id].node.name}</.link>
                <span :if={!@placements[instance.id]} class="text-sm text-base-content/60">Отдельная установка</span>
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
