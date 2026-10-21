defmodule BastionWeb.InstanceChannel do
  use Phoenix.Channel

  alias Bastion.Instances
  alias BastionWeb.Presence

  @impl true
  def join("instance:" <> instance_id, info, socket) do
    if instance_id == socket.assigns.instance_id do
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
    {:noreply, socket}
  end

  def handle_info({:push_command, command}, socket) do
    push(socket, "command", %{
      "id" => command.id,
      "action" => command.action,
      "args" => command.args
    })

    {:noreply, socket}
  end

  @impl true
  def handle_in("heartbeat", status, socket) when is_map(status) do
    Instances.record_heartbeat(socket.assigns.instance_id, status)
    {:reply, :ok, socket}
  end

  def handle_in("command_started", %{"id" => id}, socket) do
    Instances.command_started(socket.assigns.instance_id, id)
    {:reply, :ok, socket}
  end

  def handle_in("command_result", %{"id" => id, "ok" => ok?} = result, socket) do
    Instances.command_finished(socket.assigns.instance_id, id, ok? == true, result["output"])
    {:reply, :ok, socket}
  end

  def handle_in(_event, _payload, socket),
    do: {:reply, {:error, %{reason: "unknown event"}}, socket}
end
