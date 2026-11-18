defmodule BastionWeb.SessionController do
  use BastionWeb, :controller

  require Logger

  alias Bastion.LoginCodes
  alias BastionWeb.Auth

  def new(conn, _params),
    do: render(conn, :new, form: Phoenix.Component.to_form(%{}, as: :session))

  def create(conn, %{"session" => %{"login" => login, "password" => password}}) do
    cond do
      not Auth.valid_credentials?(login, password) ->
        failure_delay()

        conn
        |> put_flash(:error, "Неверный логин или пароль")
        |> render(:new, form: Phoenix.Component.to_form(%{"login" => login}, as: :session))

      LoginCodes.required?() ->
        case LoginCodes.issue(login, client_ip(conn)) do
          {:ok, id} ->
            conn
            |> put_session(:login_code_id, id)
            |> redirect(to: ~p"/login/code")

          {:error, reason} ->
            conn
            |> put_flash(:error, "Не удалось отправить код в Telegram: #{reason}")
            |> render(:new, form: Phoenix.Component.to_form(%{"login" => login}, as: :session))
        end

      true ->
        Logger.warning("Telegram is not configured, the login goes without a code")
        log_in(conn, login)
    end
  end

  def code(conn, _params) do
    if LoginCodes.pending?(get_session(conn, :login_code_id)),
      do: render(conn, :code, form: Phoenix.Component.to_form(%{}, as: :code)),
      else: redirect(conn, to: ~p"/login")
  end

  def verify(conn, %{"code" => %{"code" => code}}) do
    case LoginCodes.verify(get_session(conn, :login_code_id), code) do
      {:ok, login} ->
        log_in(conn, login)

      {:error, :invalid} ->
        failure_delay()

        conn
        |> put_flash(:error, "Неверный код")
        |> render(:code, form: Phoenix.Component.to_form(%{}, as: :code))

      {:error, reason} ->
        message =
          if reason == :too_many_attempts,
            do: "Слишком много неверных кодов, войдите заново",
            else: "Код истёк, войдите заново"

        conn
        |> delete_session(:login_code_id)
        |> put_flash(:error, message)
        |> redirect(to: ~p"/login")
    end
  end

  def delete(conn, _params) do
    conn |> configure_session(drop: true) |> redirect(to: ~p"/login")
  end

  defp log_in(conn, login) do
    conn
    |> configure_session(renew: true)
    |> delete_session(:login_code_id)
    |> put_session(:admin, login)
    |> redirect(to: ~p"/")
  end

  defp failure_delay,
    do: Process.sleep(Application.get_env(:bastion, :login_failure_delay_ms, 1_000))

  # The host nginx appends the address it saw as the last X-Forwarded-For entry.
  defp client_ip(conn) do
    case get_req_header(conn, "x-forwarded-for") do
      [forwarded | _] -> forwarded |> String.split(",") |> List.last() |> String.trim()
      [] -> conn.remote_ip |> :inet.ntoa() |> to_string()
    end
  end
end
