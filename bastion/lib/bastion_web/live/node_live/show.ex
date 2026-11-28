defmodule BastionWeb.NodeLive.Show do
  use BastionWeb, :live_view

  alias Bastion.Nodes

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    if connected?(socket), do: Nodes.subscribe()

    case Nodes.get_node(id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Сервер не найден") |> push_navigate(to: ~p"/nodes")}

      node ->
        {:ok,
         socket
         |> assign(
           page_title: node.name,
           node: node,
           registration_token: nil,
           created_instance_id: nil
         )
         |> load()}
    end
  end

  @impl true
  def handle_event("reset_registration", _, socket) do
    case Nodes.reset_registration(socket.assigns.node) do
      {:ok, node, token} -> {:noreply, assign(socket, node: node, registration_token: token)}
      _ -> {:noreply, put_flash(socket, :error, "Не удалось создать токен")}
    end
  end

  def handle_event("revoke", _, socket) do
    case Nodes.revoke(socket.assigns.node) do
      {:ok, node} ->
        {:noreply, socket |> assign(node: node) |> put_flash(:info, "Доступ ноды отозван")}

      _ ->
        {:noreply, put_flash(socket, :error, "Не удалось отозвать доступ")}
    end
  end

  def handle_event("prepare", %{"placement" => attrs}, socket) do
    hosts =
      %{"site" => attrs["site_host"], "api" => attrs["api_host"]}
      |> Map.reject(fn {_key, value} -> value in [nil, ""] end)

    case Nodes.prepare_instance(
           socket.assigns.node.id,
           attrs["instance_id"],
           attrs["name"],
           hosts,
           attrs["project_name"],
           parse_port(attrs["gateway_port"])
         ) do
      {:ok, placement} ->
        {:noreply,
         socket
         |> assign(created_instance_id: placement.instance_id)
         |> load()
         |> put_flash(:info, "Франшиза подготовлена")}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Не удалось подготовить франшизу: #{inspect(reason)}")}
    end
  end

  def handle_event("command", %{"instance-id" => id, "action" => action}, socket) do
    case Nodes.queue(id, action, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Команда поставлена в очередь")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Команда не принята: #{inspect(reason)}")}
    end
  end

  def handle_event("retry_install", %{"node" => attrs}, socket) do
    case Nodes.retry_install(socket.assigns.node, attrs) do
      {:ok, _, _} ->
        {:noreply, socket |> load() |> put_flash(:info, "Повтор установки запущен")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Повтор не начат: #{inspect(reason)}")}
    end
  end

  def handle_event("public_addresses", %{"node" => attrs}, socket) do
    case Nodes.update_public_addresses(socket.assigns.node, attrs) do
      {:ok, _} -> {:noreply, socket |> load() |> put_flash(:info, "Адреса сохранены")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Укажите публичный IP-адрес")}
    end
  end

  @impl true
  def handle_info(:nodes_updated, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    node = Nodes.get_node(socket.assigns.node.id)

    assign(socket,
      node: node,
      placements: Nodes.list_placements(node.id),
      operations: Enum.filter(Nodes.list_operations(), &(&1.node_id == node.id))
    )
  end

  defp parse_port(value) do
    case Integer.parse(value || "") do
      {port, ""} -> port
      _ -> 0
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <.link navigate={~p"/nodes"} class="link text-sm">← Серверы</.link>
      <h1 class="text-2xl font-bold">{@node.name}</h1>
      <dl class="grid gap-4 rounded-xl border border-base-300 bg-base-100 p-5 sm:grid-cols-3">
        <div>
          <dt class="text-sm text-base-content/60">Node</dt><dd>{@node.version || "Нет данных"}</dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">Последняя связь</dt><dd>
            {format_time(@node.last_seen_at)}
          </dd>
        </div>
        <div>
          <dt class="text-sm text-base-content/60">Франшиз</dt><dd>{length(@placements)}</dd>
        </div>
      </dl>
      <section class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-3">
        <h2 class="font-semibold">Подключение по SSH</h2>
        <p id="install-status">
          {@node.install_status} · {@node.install_error || "Ожидаем подключения"}
        </p>
        <p>{@node.ssh_login}@{@node.ssh_host}:{@node.ssh_port} · {@node.ssh_fingerprint}</p>
        <.form
          :if={@node.ssh_host}
          for={to_form(%{}, as: :node)}
          id="retry-node-install"
          phx-submit="retry_install"
          class="grid gap-3 sm:grid-cols-2"
        >
          <.input name="node[host]" value={@node.ssh_host} label="Адрес" required />
          <.input name="node[port]" value={@node.ssh_port} type="number" label="Порт" required />
          <.input name="node[login]" value={@node.ssh_login} label="Логин" required />
          <.input
            name="node[fingerprint]"
            value={@node.ssh_fingerprint}
            label="Отпечаток"
            required
          />
          <.input name="node[password]" value="" type="password" label="Пароль" />
          <.input name="node[private_key]" value="" type="textarea" label="Ключ" />
          <button class="btn btn-sm self-end">Повторить установку</button>
        </.form>
        <.form
          for={to_form(%{}, as: :node)}
          id="node-public-addresses"
          phx-submit="public_addresses"
          class="flex gap-3"
        >
          <.input
            name="node[public_ipv4]"
            value={@node.public_ipv4 || ""}
            label="Публичный IPv4"
          />
          <.input
            name="node[public_ipv6]"
            value={@node.public_ipv6 || ""}
            label="Публичный IPv6"
          />
          <button class="btn btn-sm self-end">Сохранить IP</button>
        </.form>
      </section>
      <section class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-3">
        <h2 class="font-semibold">Ресурсы сервера</h2>
        <p class="text-sm text-base-content/60">Замер: {format_time(@node.sampled_at)}</p>
        <p :if={not fresh?(@node)} class="text-sm text-warning">
          Связь с нодой потеряна. Показатели устарели.
        </p>
        <div class="grid gap-4 sm:grid-cols-3">
          <div>
            <span class="text-sm text-base-content/60">CPU</span><p class="font-semibold">
              {percent(@node.metrics["cpu_percent"])} · {count(@node.metrics["cpus"])} ядер
            </p>
          </div>
          <div>
            <span class="text-sm text-base-content/60">RAM доступно</span><p class="font-semibold">
              {gigabytes(get_in(@node.metrics, ["memory", "available_kb"]))} из {gigabytes(
                get_in(@node.metrics, ["memory", "total_kb"])
              )}
            </p>
          </div>
          <div>
            <span class="text-sm text-base-content/60">Диск</span><p
              :for={disk <- List.wrap(@node.metrics["disks"])}
              class="font-semibold"
            >
              {disk["filesystem"]}: {gigabytes(disk["free_kb"])} свободно · {percent(
                disk["used_percent"]
              )} занято
            </p><p :if={List.wrap(@node.metrics["disks"]) == []}>Нет данных</p>
          </div>
        </div>
      </section>
      <section id="renewal-status" class="rounded-xl border border-base-300 bg-base-100 p-5">
        <h2 class="font-semibold">Продление сертификатов</h2>
        <p>
          {if get_in(@node.infrastructure, ["renewal", "ok"]) == true,
            do: "Проверено",
            else: "Требует проверки"}
        </p>
        <p>
          Последняя проверка: {get_in(@node.infrastructure, ["renewal", "checked_at"]) || "Нет данных"}
        </p>
        <p :if={get_in(@node.infrastructure, ["renewal", "error"])} class="text-error">
          {get_in(@node.infrastructure, ["renewal", "error"])}
        </p>
      </section>
      <section class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-3">
        <h2 class="font-semibold">Доступ ноды</h2>
        <div class="flex flex-wrap gap-2">
          <button type="button" class="btn btn-sm" phx-click="reset_registration">Новый токен регистрации</button>
          <button type="button" class="btn btn-sm btn-error" phx-click="revoke">Отозвать доступ</button>
        </div>
        <code :if={@registration_token} class="block break-all select-all">{@registration_token}</code>
      </section>
      <section class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-3">
        <h2 class="font-semibold">Подготовленная установка</h2>
        <p class="text-sm text-base-content/60">
          Укажите постоянный ID из локального реестра Node и данные подготовленного Compose-проекта.
        </p>
        <.form
          id="prepare-instance"
          for={%{}}
          as={:placement}
          phx-submit="prepare"
          class="grid gap-3 sm:grid-cols-3"
        >
          <.input name="placement[instance_id]" value="" label="ID франшизы (UUID)" required />
          <.input name="placement[name]" value="" label="Название франшизы" required />
          <.input name="placement[project_name]" value="" label="Compose-проект" required />
          <.input
            name="placement[gateway_port]"
            value=""
            type="number"
            label="Порт gateway"
            required
          />
          <.input name="placement[site_host]" value="" label="Адрес сайта" />
          <.input name="placement[api_host]" value="" label="Адрес API" />
          <button class="btn btn-primary self-end">Подготовить</button>
        </.form>
        <p :if={@created_instance_id} class="text-sm">
          ID подготовленной франшизы: <code class="select-all">{@created_instance_id}</code>
        </p>
      </section>
      <section class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-3">
        <h2 class="font-semibold">Франшизы на сервере</h2>
        <div
          :for={placement <- @placements}
          class="flex flex-wrap items-center gap-3 border-t border-base-300 pt-3"
        >
          <.link navigate={~p"/instances/#{placement.instance_id}"} class="link font-semibold">{placement.instance.name}</.link>
          <span class="text-sm text-base-content/60">{placement.project_name} · 127.0.0.1:{placement.gateway_port} · {placement.observed_state ||
            "Нет данных"}</span>
          <div class="ml-auto flex gap-2">
            <button
              :for={action <- ~w(status stop start)}
              type="button"
              class="btn btn-sm"
              phx-click="command"
              phx-value-instance-id={placement.instance_id}
              phx-value-action={action}
            >{action_label(action)}</button>
          </div>
        </div>
        <p :if={@placements == []} class="text-base-content/60">Нет размещённых франшиз.</p>
      </section>
      <section class="rounded-xl border border-base-300 bg-base-100 p-5 space-y-3">
        <h2 class="font-semibold">Последние операции</h2>
        <.link navigate={~p"/operations"} class="link text-sm">Открыть журнал</.link>
        <p :for={operation <- Enum.take(@operations, 10)} class="text-sm">
          {operation.action} · {operation.status} · {operation.instance && operation.instance.name}
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp action_label("status"), do: "Статус"
  defp action_label("stop"), do: "Остановить"
  defp action_label("start"), do: "Запустить"
  defp format_time(nil), do: "Нет данных"
  defp format_time(at), do: Calendar.strftime(at, "%d.%m.%Y %H:%M UTC")
  defp fresh?(%{last_seen_at: nil}), do: false
  defp fresh?(%{credential_revoked_at: revoked}) when not is_nil(revoked), do: false
  defp fresh?(%{last_seen_at: at}), do: DateTime.diff(DateTime.utc_now(), at) < 90

  defp percent(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1, decimals: 1) <> "%"

  defp percent(_), do: "Нет данных"
  defp count(value) when is_integer(value), do: value
  defp count(_), do: "—"

  defp gigabytes(value) when is_number(value),
    do: :erlang.float_to_binary(value / 1_048_576, decimals: 1) <> " ГиБ"

  defp gigabytes(_), do: "Нет данных"
end
