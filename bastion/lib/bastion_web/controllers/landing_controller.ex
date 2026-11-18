defmodule BastionWeb.LandingController do
  use BastionWeb, :controller
  alias Bastion.Landing

  def config(conn, _params), do: json(conn, Landing.public_config())

  def event(conn, params) do
    with :ok <- guard_request(conn, params, 120),
         {:ok, _} <- Landing.record_event(params) do
      conn |> put_status(:accepted) |> json(%{ok: true})
    else
      {:error, :rate_limited} -> error(conn, :too_many_requests)
      _ -> error(conn, :unprocessable_entity)
    end
  end

  def lead(conn, params) do
    with :ok <- guard_request(conn, params, 10),
         {:ok, result} <- Landing.record_lead(params) do
      response =
        case result do
          :honeypot -> %{ok: true, saved: false}
          lead -> %{ok: true, saved: true, lead_id: lead.id}
        end

      conn |> put_status(:accepted) |> json(response)
    else
      {:error, :rate_limited} -> error(conn, :too_many_requests)
      _ -> error(conn, :unprocessable_entity)
    end
  end

  defp guard_request(conn, params, limit) do
    agent = conn |> get_req_header("user-agent") |> List.first() || ""

    cond do
      byte_size(agent) > 500 or Regex.match?(~r/(bot|crawler|spider|headless)/i, agent) ->
        {:error, :invalid_agent}

      not rate_allowed?(conn, params, limit) ->
        {:error, :rate_limited}

      true ->
        :ok
    end
  end

  defp rate_allowed?(conn, params, limit) do
    session = Map.get(params, "session_id")
    session = if is_binary(session) and byte_size(session) <= 80, do: session, else: "invalid"

    Bastion.Landing.RateLimiter.allow?({:session, session, limit}, limit) and
      Bastion.Landing.RateLimiter.allow?({:ip, conn.remote_ip, limit}, 1000)
  end

  defp error(conn, status),
    do: conn |> put_status(status) |> json(%{error: Atom.to_string(status)})
end
