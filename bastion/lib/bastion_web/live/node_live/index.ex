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
              <td>{if fresh?(node), do: "На связи", else: "Нет связи"}</td>
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

  defp fresh?(%{last_seen_at: nil}), do: false
  defp fresh?(%{credential_revoked_at: revoked}) when not is_nil(revoked), do: false
  defp fresh?(%{last_seen_at: at}), do: DateTime.diff(DateTime.utc_now(), at) < 90
  defp format_time(nil), do: "Нет данных"
  defp format_time(at), do: Calendar.strftime(at, "%d.%m.%Y %H:%M UTC")
end
