defmodule BastionWeb.OperationsLive do
  use BastionWeb, :live_view

  alias Bastion.Nodes

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Nodes.subscribe()
    {:ok, socket |> assign(page_title: "Операции") |> load()}
  end

  @impl true
  def handle_info(:nodes_updated, socket), do: {:noreply, load(socket)}

  defp load(socket), do: assign(socket, operations: Nodes.list_operations())

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <h1 class="text-2xl font-bold">Журнал операций</h1>
      <div class="overflow-x-auto rounded-xl border border-base-300 bg-base-100">
        <table class="table" id="operations">
          <thead>
            <tr>
              <th>Время</th><th>Франшиза</th><th>Сервер</th><th>Действие</th><th>Состояние</th><th>
                Результат
              </th>
            </tr>
          </thead>
          <tbody>
            <tr :for={operation <- @operations} id={"operation-#{operation.id}"}>
              <td>{Calendar.strftime(operation.inserted_at, "%d.%m.%Y %H:%M UTC")}</td>
              <td>{(operation.instance && operation.instance.name) || "—"}</td>
              <td>
                <.link navigate={~p"/nodes/#{operation.node_id}"} class="link">{operation.node.name}</.link>
              </td>
              <td>{operation.action}</td>
              <td>{status_label(operation.status)}</td>
              <td class="max-w-md break-words">{result_label(operation)}</td>
            </tr>
          </tbody>
        </table>
        <p :if={@operations == []} class="p-5 text-base-content/60">Операций пока нет.</p>
      </div>
    </Layouts.app>
    """
  end

  defp status_label("pending"), do: "Ожидает"
  defp status_label("running"), do: "Выполняется"
  defp status_label("waiting_external"), do: "Ожидает внешнего условия"
  defp status_label("ok"), do: "Успешно"
  defp status_label("error"), do: "Ошибка"
  defp status_label("unknown"), do: "Результат неизвестен"
  defp result_label(%{result: result}) when result == %{}, do: "—"

  defp result_label(%{result: result}),
    do: result["message"] || result["reason"] || "См. карточку франшизы"
end
