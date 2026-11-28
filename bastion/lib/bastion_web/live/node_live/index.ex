defmodule BastionWeb.NodeLive.Index do
  use BastionWeb, :live_view

  alias Bastion.Nodes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Nodes.subscribe()

    {:ok,
     socket
     |> assign(page_title: "Серверы", registration_token: nil, created_node: nil)
     |> load()}
  end

  @impl true
  def handle_event("create", %{"node" => %{"name" => name}}, socket) do
    case Nodes.create_node(name) do
      {:ok, node, token} ->
        {:noreply, socket |> assign(created_node: node, registration_token: token) |> load()}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Укажите название сервера")}
    end
  end

  def handle_event("install", %{"node" => attrs}, socket) do
    case Nodes.start_install(attrs["name"], attrs) do
      {:ok, node, _operation} ->
        {:noreply, push_navigate(socket, to: ~p"/nodes/#{node.id}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Подключение не начато: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_info(:nodes_updated, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, nodes: Nodes.list_nodes())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <div class="flex flex-wrap items-center justify-between gap-4">
        <h1 class="text-2xl font-bold">Серверы</h1>
        <span class="text-sm text-base-content/60">{length(@nodes)} серверов</span>
      </div>

      <section class="rounded-xl border border-base-300 bg-base-100 p-5">
        <h2 class="mb-3 font-semibold">Подключить сервер по SSH</h2>
        <.form
          for={to_form(%{}, as: :node)}
          id="install-node"
          phx-submit="install"
          class="grid gap-3 sm:grid-cols-2"
        >
          <.input name="node[name]" value="" label="Название сервера" required />
          <.input name="node[host]" value="" label="IP или имя сервера" required />
          <.input name="node[port]" value="22" type="number" label="SSH-порт" required />
          <.input name="node[login]" value="root" label="SSH-логин" required />
          <.input
            name="node[fingerprint]"
            value=""
            label="Отпечаток SSH Ed25519 (SHA256:...)"
            required
          />
          <.input name="node[password]" value="" type="password" label="SSH-пароль" />
          <.input
            name="node[private_key]"
            value=""
            type="textarea"
            label="Приватный SSH-ключ"
          />
          <button class="btn btn-primary self-end">Подключить</button>
        </.form>
      </section>
      <section class="rounded-xl border border-base-300 bg-base-100 p-5">
        <h2 class="mb-3 font-semibold">Подготовить тестовую ноду</h2>
        <.form for={%{}} as={:node} phx-submit="create" class="flex flex-wrap gap-2">
          <.input name="node[name]" value="" label="Название сервера" required />
          <button class="btn btn-primary self-end">Создать</button>
        </.form>
        <div :if={@registration_token} class="alert alert-info mt-4 block break-all" role="status">
          <strong>Токен регистрации для {@created_node.name}</strong>
          <code class="mt-2 block select-all">{@registration_token}</code>
          <span class="text-sm">Сохраните его для запуска Delivest Node. Он показан один раз.</span>
        </div>
      </section>

      <div class="overflow-x-auto rounded-xl border border-base-300 bg-base-100">
        <table class="table" id="nodes">
          <thead>
            <tr>
              <th>Сервер</th><th>Связь</th><th>Версия Node</th><th>Последний ответ</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={node <- @nodes} id={"node-#{node.id}"}>
              <td>
                <.link navigate={~p"/nodes/#{node.id}"} class="link font-semibold">{node.name}</.link>
              </td>
              <td>{if Nodes.ready?(node), do: "Готова", else: node.install_status}</td>
              <td>{node.version || "—"}</td>
              <td>{format_time(node.last_seen_at)}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@nodes == []} class="p-5 text-base-content/60">Серверы пока не добавлены.</p>
      </div>
    </Layouts.app>
    """
  end

  defp format_time(nil), do: "Нет данных"
  defp format_time(at), do: Calendar.strftime(at, "%d.%m.%Y %H:%M UTC")
end
