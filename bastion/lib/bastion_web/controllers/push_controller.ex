defmodule BastionWeb.PushController do
  use BastionWeb, :controller

  alias Bastion.Push

  def create(conn, %{"endpoint" => endpoint, "keys" => %{"p256dh" => p256dh, "auth" => auth}}) do
    attrs = %{
      endpoint: endpoint,
      p256dh: p256dh,
      auth: auth,
      user_agent: conn |> get_req_header("user-agent") |> List.first()
    }

    case Push.subscribe(attrs, get_session(conn, :admin)) do
      {:ok, _subscription} -> json(conn, %{ok: true})
      {:error, _changeset} -> conn |> put_status(:unprocessable_entity) |> json(%{ok: false})
    end
  end

  def delete(conn, %{"endpoint" => endpoint}) do
    Push.unsubscribe(endpoint)
    json(conn, %{ok: true})
  end
end
