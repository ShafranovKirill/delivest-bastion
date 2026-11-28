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

  pipeline :session_json do
    plug :accepts, ["json"]
    plug :fetch_session
    plug :protect_from_forgery
  end

  pipeline :admin do
    plug :require_admin
  end

  pipeline :landing_json do
    plug :accepts, ["json"]
  end

  scope "/api/landing", BastionWeb do
    pipe_through :landing_json
    get "/config", LandingController, :config
    post "/events", LandingController, :event
    post "/leads", LandingController, :lead
  end

  scope "/", BastionWeb do
    pipe_through :browser

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/login/code", SessionController, :code
    post "/login/code", SessionController, :verify
    delete "/logout", SessionController, :delete
  end

  scope "/telegram", BastionWeb do
    post "/webhook", TelegramController, :create
  end

  scope "/agent", BastionWeb do
    put "/backups/:id", BackupController, :upload
    get "/backups/:id/file", BackupController, :file
    put "/backups/snapshots/:id", SnapshotController, :upload
  end

  scope "/node", BastionWeb do
    pipe_through :landing_json
    post "/register", NodeRegistrationController, :create
  end

  scope "/push", BastionWeb do
    pipe_through [:session_json, :admin]

    post "/subscriptions", PushController, :create
    delete "/subscriptions", PushController, :delete
  end

  scope "/", BastionWeb do
    pipe_through [:browser, :admin]

    get "/backups/:id/download", BackupController, :download
    get "/backups/snapshots/:id/download", SnapshotController, :download

    live_session :admin, on_mount: [{BastionWeb.Auth, :require_admin}] do
      live "/", OverviewLive, :index
      live "/instances", InstanceLive.Index, :index
      live "/instances/:id", InstanceLive.Show, :show
      live "/nodes", NodeLive.Index, :index
      live "/nodes/:id", NodeLive.Show, :show
      live "/domains", DomainLive.Index, :index
      live "/domains/:id", DomainLive.Show, :show
      live "/operations", OperationsLive, :index
      live "/landing", LandingLive, :index
    end
  end
end
