defmodule BastionWeb.Router do
  use BastionWeb, :router

  import BastionWeb.Auth, only: [require_admin: 2]

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {BastionWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :admin do
    plug :require_admin
  end

  scope "/", BastionWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    delete "/logout", SessionController, :delete
  end

  scope "/", BastionWeb do
    pipe_through [:browser, :admin]

    live_session :admin, on_mount: [{BastionWeb.Auth, :require_admin}] do
      live "/", InstanceLive.Index, :index
      live "/instances/:id", InstanceLive.Show, :show
    end
  end
end
