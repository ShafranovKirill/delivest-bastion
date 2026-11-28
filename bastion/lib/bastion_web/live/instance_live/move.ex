defmodule BastionWeb.InstanceLive.Move do
  use BastionWeb, :live_view

  alias Bastion.{Instances, ManagedMove, Nodes}

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket) do
      Nodes.subscribe()
      :timer.send_interval(:timer.seconds(15), :refresh)
    end

    case {Instances.get_instance(id), Nodes.placement_for(id)} do
      {%{transport: "node"}, %Nodes.Placement{}} ->
        {:ok, socket |> assign(page_title: "Перенос франшизы", instance_id: id) |> load()}

      _ ->
        {:ok, push_navigate(socket, to: ~p"/instances")}
    end
  end

  @impl true
  def handle_event("reserve", %{"move" => attrs}, socket) do
    port =
      case Integer.parse(attrs["port"] || "") do
        {value, ""} -> value
        _ -> 0
      end

    result =
      ManagedMove.reserve(
        socket.assigns.instance_id,
        attrs["node_id"],
        port,
        attrs["mode"],
        attrs["evidence"],
        socket.assigns.current_admin
      )

    case result do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Размещение зарезервировано") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Перенос не подготовлен: #{inspect(reason)}")}
    end
  end

  def handle_event("confirm", _params, socket) do
    case ManagedMove.confirm(socket.assigns.move.id, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Новое размещение активировано") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Нельзя активировать: #{inspect(reason)}")}
    end
  end

  def handle_event("cancel", %{"cancellation" => attrs}, socket) do
    case ManagedMove.cancel(
           socket.assigns.move.id,
           socket.assigns.current_admin,
           attrs["confirmation"],
           attrs["evidence"]
         ) do
      {:ok, _} ->
        {:noreply, socket |> put_flash(:info, "Резервирование отменено") |> load()}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Нельзя отменить: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(:nodes_updated, socket), do: {:noreply, load(socket)}
  def handle_info(_, socket), do: {:noreply, socket}

  defp load(socket) do
    instance = Instances.get_instance(socket.assigns.instance_id)
    source = Nodes.placement_for(instance.id)
    move = ManagedMove.pending(instance.id)

    assign(socket,
      instance: instance,
      source: source,
      move: move,
      instructions: if(move, do: ManagedMove.instructions(move), else: nil),
      targets:
        Enum.filter(
          Nodes.list_nodes(),
          &(&1.id != source.node_id and Nodes.ready?(&1) and not &1.maintenance)
        )
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <div class="space-y-6">
        <.link navigate={~p"/instances/#{@instance.id}"} class="link">← {@instance.name}</.link>
        <div>
          <h1 class="text-2xl font-bold">Перенос франшизы</h1>
          <p class="text-sm text-base-content/70">
            Источник — {@source.node.name}. Постоянный ID {@instance.id}.
          </p>
        </div>

        <section :if={!@move} class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-4">
          <h2 class="font-semibold">Зарезервировать место на другой ноде</h2>
          <p class="text-sm">
            Для планового переноса сначала остановите источник и создайте полную копию после остановки. Для аварийного переноса подтвердите внешнее ограждение недоступного источника.
          </p>
          <.form
            for={to_form(%{}, as: :move)}
            id="move-form"
            phx-submit="reserve"
            class="grid gap-3 max-w-xl"
          >
            <.input
              name="move[node_id]"
              type="select"
              value=""
              label="Целевая нода"
              options={Enum.map(@targets, &{&1.name, &1.id})}
              prompt="Выберите ноду"
              required
            />
            <.input
              name="move[port]"
              type="number"
              value=""
              label="Свободный loopback-порт gateway"
              min="1024"
              max="65535"
              required
            />
            <.input
              name="move[mode]"
              type="select"
              value="planned"
              label="Сценарий"
              options={[{"Плановый", "planned"}, {"Аварийный", "disaster"}]}
            />
            <.input
              name="move[evidence]"
              type="text"
              value=""
              label="Подтверждение внешнего ограждения для аварийного сценария"
            />
            <button class="btn btn-primary" disabled={@targets == []}>Зарезервировать</button>
          </.form>
        </section>

        <section
          :if={@move}
          id="move-progress"
          class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-4"
        >
          <h2 class="font-semibold">Подготовка размещения</h2>
          <p>
            Операция {@move.id}. Целевая нода {@instructions.target.node.name}, ревизия {@instructions.target.revision}, порт {@instructions.target.gateway_port}.
          </p>
          <p>Архив {@instructions.snapshot_id}, SHA-256 {@instructions.snapshot_sha256}.</p>
          <p class="text-sm">
            Скачайте указанный архив из карточки франшизы. На целевой ноде выполните команду с локальным путём к архиву.
          </p>
          <pre class="overflow-x-auto rounded-lg bg-base-200 p-3 text-xs"><code>python3 priv/stage-placement-transfer.py --archive /path/to/archive.tar.gz --sha256 {@instructions.snapshot_sha256} --instance-id {@instance.id} --revision {@instructions.target.revision} --gateway-port {@instructions.target.gateway_port} --operation-id {@move.id}</code></pre>
          <p class="text-sm">
            Скрипт выведет registration_base64. Зарегистрируйте созданный проект через Node RPC.
          </p>
          <pre class="overflow-x-auto rounded-lg bg-base-200 p-3 text-xs"><code>bin/delivest_node rpc 'DelivestNode.CLI.register_base64("&lt;registration_base64&gt;")'</code></pre>
          <p class="text-sm">
            После ограждения источника и публикации DNS на целевой IP запустите проект и подготовьте маршруты.
          </p>
          <pre class="overflow-x-auto rounded-lg bg-base-200 p-3 text-xs"><code>bin/delivest_node rpc 'DelivestNode.Transfer.prepare_base64("{@instructions.prepare_base64}")'</code></pre>
          <p class="text-sm">
            После свежего heartbeat целевой ноды и успешной публичной проверки сайта и API подтвердите переключение.
          </p>
          <button id="move-confirm" phx-click="confirm" class="btn btn-primary">Проверить и активировать</button>
          <.form
            for={to_form(%{}, as: :cancellation)}
            id="move-cancel-form"
            phx-submit="cancel"
            class="space-y-2"
          >
            <input type="hidden" name="cancellation[confirmation]" value="target_removed_and_fenced" />
            <.input
              name="cancellation[evidence]"
              type="text"
              value=""
              label="Как проверено удаление и ограждение целевой установки"
              required
            />
            <button id="move-cancel" class="btn btn-ghost">Подтверждаю отсутствие запуска и отменяю резервирование</button>
          </.form>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
