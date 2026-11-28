defmodule BastionWeb.NodeRegistrationController do
  use BastionWeb, :controller

  def create(conn, %{"token" => token, "protocol_version" => version}) do
    case Bastion.Nodes.register(token, version) do
      {:ok, node, credential} ->
        json(conn, %{node_id: node.id, credential: credential, protocol_version: 1})

      {:error, :unsupported_protocol} ->
        conn |> put_status(:unprocessable_entity) |> json(%{error: "unsupported_protocol"})

      _ ->
        conn |> put_status(:unauthorized) |> json(%{error: "invalid_token"})
    end
  end

  def create(conn, _params),
    do: conn |> put_status(:bad_request) |> json(%{error: "invalid_request"})
end
