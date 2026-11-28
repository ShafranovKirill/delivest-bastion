defmodule BastionWeb.OverviewLive do
  use BastionWeb, :live_view

  alias Bastion.{Downtime, Health, Instances, Nodes}

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Nodes.subscribe()
      Instances.subscribe()
      :timer.send_interval(15_000, :refresh)
    end

    {:ok, socket |> assign(page_title: "Обзор") |> load()}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load(socket)}
  def handle_info(:nodes_updated, socket), do: {:noreply, load(socket)}
  def handle_info({_, _}, socket), do: {:noreply, load(socket)}

  defp load(socket) do
    nodes = Nodes.list_nodes()
    instances = Instances.list_instances()
    unreachable = Enum.filter(instances, &(Health.evaluate(&1).level == :down))
    no_fresh_data = Enum.filter(instances, &(Health.evaluate(&1).level == :unknown))

    disconnected =
      Enum.filter(
        nodes,
        &(is_nil(&1.last_seen_at) or not is_nil(&1.credential_revoked_at) or
            DateTime.diff(DateTime.utc_now(), &1.last_seen_at) > 90)
      )

    operations = Nodes.list_operations(100)

    assign(socket,
      nodes: nodes,
      instances: instances,
      unreachable: unreachable,
      no_fresh_data: no_fresh_data,
      disconnected: disconnected,
      operations: operations,
      recent_errors: operations |> Enum.filter(&(&1.status == "error")) |> Enum.take(10),
      recent_incidents: Downtime.recent_incidents(10)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <h1 class="text-2xl font-bold">Обзор</h1>
      <div class={[
        "rounded-xl border p-5",
        (@unreachable != [] or @disconnected != []) && "border-error/40 bg-error/10",
        @unreachable == [] and @disconnected == [] && "border-success/40 bg-success/10"
      ]}>
        <p class="text-lg font-semibold">
          {summary(@unreachable, @disconnected, @no_fresh_data, @nodes, @instances)}
        </p>
        <p :if={@unreachable != []} class="text-sm">
          Недоступны сайты: {Enum.map_join(@unreachable, ", ", & &1.name)}
        </p>
        <p :if={@disconnected != []} class="text-sm">
          Нет связи с нодой: {Enum.map_join(@disconnected, ", ", & &1.name)}
        </p>
        <p :if={@no_fresh_data != []} class="text-sm">
          Нет свежих данных: {Enum.map_join(@no_fresh_data, ", ", & &1.name)}
        </p>
      </div>
      <div class="grid gap-4 md:grid-cols-2">
        <section class="rounded-xl border border-base-300 bg-base-100 p-5">
          <div class="flex justify-between">
            <h2 class="font-semibold">Серверы</h2><.link navigate={~p"/nodes"} class="link text-sm">Все серверы</.link>
          </div>
          <p :for={node <- @nodes} class="mt-3">
            <.link navigate={~p"/nodes/#{node.id}"} class="link">{node.name}</.link>
            · {if node in @disconnected, do: "Нет связи", else: "На связи"}
          </p>
          <p :if={@nodes == []} class="mt-3 text-base-content/60">Нет подключённых серверов.</p>
        </section>
        <section class="rounded-xl border border-base-300 bg-base-100 p-5">
          <div class="flex justify-between">
            <h2 class="font-semibold">Франшизы</h2><.link
              navigate={~p"/instances"}
              class="link text-sm"
            >Все франшизы</.link>
          </div>
          <p class="mt-3 text-3xl font-bold">{length(@instances)}</p>
        </section>
      </div>
      <section class="rounded-xl border border-base-300 bg-base-100 p-5">
        <div class="flex justify-between">
          <h2 class="font-semibold">Последние ошибки</h2><.link
            navigate={~p"/operations"}
            class="link text-sm"
          >Журнал</.link>
        </div>
        <p :for={incident <- @recent_incidents} class="mt-3 text-sm">
          {format_time(incident.started_at)} · {incident.instance.name} · {Enum.join(
            incident.problems,
            ", "
          )} · {if incident.ended_at, do: "Устранена", else: "Активна"}
        </p>
        <p :for={operation <- @recent_errors} class="mt-3 text-sm">
          {format_time(operation.inserted_at)} · {(operation.instance && operation.instance.name) ||
            operation.node.name} · {operation.action} · {operation.result["reason"] ||
            "Ошибка выполнения"} · {if resolved?(operation, @operations),
            do: "Устранена",
            else: "Активна"}
        </p>
        <p :if={@recent_errors == [] and @recent_incidents == []} class="mt-3 text-base-content/60">
          Ошибок нет.
        </p>
      </section>
    </Layouts.app>
    """
  end

  defp summary([], [], [], [], []), do: "Нет свежих данных"
  defp summary([], [], [], _, _), do: "Всё работает"
  defp summary([], [], _, _, _), do: "Нет свежих данных"
  defp summary(_, _, _, _, _), do: "Требуется внимание"

  defp resolved?(error, operations) do
    Enum.any?(operations, fn operation ->
      operation.status == "ok" and operation.instance_id == error.instance_id and
        operation.action == error.action and
        DateTime.compare(operation.inserted_at, error.inserted_at) == :gt
    end)
  end

  defp format_time(at), do: Calendar.strftime(at, "%d.%m.%Y %H:%M UTC")
end
