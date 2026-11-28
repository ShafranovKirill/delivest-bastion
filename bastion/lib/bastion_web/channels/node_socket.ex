defmodule BastionWeb.NodeSocket do
  use Phoenix.Socket

  channel "node:*", BastionWeb.NodeChannel

  @impl true
  def connect(_params, socket, connect_info) do
    credential =
      connect_info
      |> Map.get(:x_headers, [])
      |> Enum.find_value(fn
        {"x-delivest-node-token", token} -> token
        _ -> nil
      end)

    case Bastion.Nodes.authenticate_credential(credential) do
      {:ok, node} ->
        {:ok, assign(socket, node_id: node.id, credential_revision: node.credential_revision)}

      _ ->
        :error
    end
  end

  @impl true
  def id(socket), do: "node:#{socket.assigns.node_id}"
end
