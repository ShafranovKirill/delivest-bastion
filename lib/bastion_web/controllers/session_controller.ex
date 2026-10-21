defmodule BastionWeb.SessionController do
  use BastionWeb, :controller

  alias BastionWeb.Auth

  def new(conn, _params),
    do: render(conn, :new, form: Phoenix.Component.to_form(%{}, as: :session))

  def create(conn, %{"session" => %{"login" => login, "password" => password}}) do
    if Auth.valid_credentials?(login, password) do
      conn
      |> configure_session(renew: true)
      |> put_session(:admin, login)
      |> redirect(to: ~p"/")
    else
      Process.sleep(Application.get_env(:bastion, :login_failure_delay_ms, 1_000))

      conn
      |> put_flash(:error, "Неверный логин или пароль")
      |> render(:new, form: Phoenix.Component.to_form(%{"login" => login}, as: :session))
    end
  end

  def delete(conn, _params) do
    conn |> configure_session(drop: true) |> redirect(to: ~p"/login")
  end
end
