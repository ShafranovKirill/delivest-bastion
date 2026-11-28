defmodule BastionWeb.NodeChannel do
  use Phoenix.Channel

  alias Bastion.Nodes

  @impl true
  def join("node:" <> node_id, %{"protocol_version" => 1}, socket) do
    if node_id == socket.assigns.node_id and authorized?(socket) do
      send(self(), :after_join)
      {:ok, socket}
    else
      {:error, %{reason: "unauthorized"}}
    end
  end

  def join(_, _, _), do: {:error, %{reason: "unsupported_protocol"}}

  @impl true
  def handle_info(:after_join, socket) do
    if authorized?(socket) do
      Nodes.subscribe_commands(socket.assigns.node_id)

      for operation <- Nodes.pending_operations(socket.assigns.node_id) do
        push(socket, "command", Nodes.command_payload(operation))
      end
    end

    {:noreply, socket}
  end

  def handle_info({:push_operation, operation}, socket) do
    if authorized?(socket) and Nodes.deliverable?(operation),
      do: push(socket, "command", Nodes.command_payload(operation))

    {:noreply, socket}
  end

  @impl true
  def handle_in("heartbeat", payload, socket) do
    with :ok <- authorize(socket),
         :ok <- Nodes.record_heartbeat(socket.assigns.node_id, payload) do
      {:reply, :ok, socket}
    else
      _ -> {:reply, {:error, %{reason: "invalid_heartbeat"}}, socket}
    end
  end

  def handle_in("bootstrap_credentials", payload, socket) do
    with :ok <- authorize(socket),
         :ok <- Nodes.store_bootstrap_credentials(socket.assigns.node_id, payload) do
      push(socket, "bootstrap_credentials_ack", %{
        instance_id: payload["instance_id"],
        placement_revision: payload["placement_revision"]
      })

      {:reply, :ok, socket}
    else
      _ -> {:reply, {:error, %{reason: "invalid_bootstrap_credentials"}}, socket}
    end
  end

  def handle_in(event, %{"operation_id" => operation_id} = payload, socket)
      when event in ~w(command_ack command_progress command_result) do
    with :ok <- authorize(socket),
         {:ok, _operation} <-
           Nodes.update_operation(socket.assigns.node_id, operation_id, event, payload) do
      {:reply, :ok, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: to_string(reason)}}, socket}
    end
  end

  def handle_in(_, _, socket), do: {:reply, {:error, %{reason: "unknown_event"}}, socket}

  defp authorized?(socket), do: authorize(socket) == :ok

  defp authorize(socket) do
    if Nodes.credential_active?(socket.assigns.node_id, socket.assigns.credential_revision),
      do: :ok,
      else: {:error, :unauthorized}
  end
end
