defmodule BastionWeb.Auth do
  import Plug.Conn
  import Phoenix.Controller

  use BastionWeb, :verified_routes

  def valid_credentials?(login, password) when is_binary(login) and is_binary(password) do
    expected_login = Application.get_env(:bastion, :admin_login, "admin")
    expected_password = Application.get_env(:bastion, :admin_password)

    is_binary(expected_password) and
      Plug.Crypto.secure_compare(login, expected_login) and
      Plug.Crypto.secure_compare(password, expected_password)
  end

  def valid_credentials?(_login, _password), do: false

  def require_admin(conn, _opts) do
    if get_session(conn, :admin) do
      conn
    else
      conn |> redirect(to: ~p"/login") |> halt()
    end
  end

  def on_mount(:require_admin, _params, session, socket) do
    case session["admin"] do
      nil -> {:halt, Phoenix.LiveView.redirect(socket, to: ~p"/login")}
      admin -> {:cont, Phoenix.Component.assign(socket, :current_admin, admin)}
    end
  end
end
