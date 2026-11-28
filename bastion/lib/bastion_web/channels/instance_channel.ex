defmodule BastionWeb.InstanceChannel do
  use Phoenix.Channel

  alias Bastion.{Backups, CrmAlerts, Instances, Metrics, SiteAlerts, Snapshots}
  alias BastionWeb.Presence

  @impl true
  def join("instance:" <> instance_id, info, socket) do
    if instance_id == socket.assigns.instance_id and legacy_instance?(instance_id) do
      case Instances.register(instance_id, info) do
        {:ok, _instance} ->
          send(self(), :after_join)
          {:ok, socket}

        {:error, _changeset} ->
          {:error, %{reason: "invalid info"}}
      end
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  @impl true
  def handle_info(:after_join, socket) do
    Instances.subscribe_commands(socket.assigns.instance_id)
    {:ok, _ref} = Presence.track_agent(self(), socket.assigns.instance_id)

    for command <- Instances.pending_commands(socket.assigns.instance_id) do
      send(self(), {:push_command, command})
    end

    {:noreply, socket}
  end

  def handle_info({:push_command, command}, socket) do
    if legacy_instance?(socket.assigns.instance_id) do
      args = if command.action == "update", do: Backups.retry_args(command), else: command.args

      push(socket, "command", %{
        "id" => command.id,
        "action" => command.action,
        "args" => args
      })
    end

    {:noreply, socket}
  end

  @impl true
  def handle_in("heartbeat", status, socket) when is_map(status) do
    if legacy_instance?(socket.assigns.instance_id) do
      previous = Instances.get_instance(socket.assigns.instance_id)
      Instances.record_heartbeat(socket.assigns.instance_id, status)
      Instances.drop_lost_commands(socket.assigns.instance_id, status)
      if previous, do: SiteAlerts.check(previous, status)
      CrmAlerts.check(socket.assigns.instance_id, status["crm"])

      with {:ok, _sample} <- Metrics.record(socket.assigns.instance_id, status["metrics"]),
           do: Metrics.Alerts.check(socket.assigns.instance_id)

      {:reply, :ok, socket}
    else
      {:reply, {:error, %{reason: "managed_by_node"}}, socket}
    end
  end

  def handle_in("command_started", %{"id" => id}, socket) do
    if legacy_instance?(socket.assigns.instance_id) do
      Instances.command_started(socket.assigns.instance_id, id)
      {:reply, :ok, socket}
    else
      {:reply, {:error, %{reason: "managed_by_node"}}, socket}
    end
  end

  def handle_in("command_result", %{"id" => id, "ok" => ok?} = result, socket) do
    if legacy_instance?(socket.assigns.instance_id) do
      with {:ok, command} <-
             Instances.command_finished(
               socket.assigns.instance_id,
               id,
               ok? == true,
               result["output"]
             ),
           do:
             (
               Backups.command_finished(command)
               Snapshots.command_finished(command)
             )

      {:reply, :ok, socket}
    else
      {:reply, {:error, %{reason: "managed_by_node"}}, socket}
    end
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unknown event"}}, socket}

  defp legacy_instance?(id) do
    case Instances.get_instance(id) do
      %{transport: "node"} -> false
      _ -> true
    end
  end
end
