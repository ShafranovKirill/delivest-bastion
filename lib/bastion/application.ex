defmodule Bastion.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BastionWeb.Telemetry,
      Bastion.Repo,
      {DNSCluster, query: Application.get_env(:bastion, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Bastion.PubSub},
      BastionWeb.Presence,
      {Oban, Application.fetch_env!(:bastion, Oban)},
      # Start a worker by calling: Bastion.Worker.start_link(arg)
      # {Bastion.Worker, arg},
      # Start to serve requests, typically the last entry
      BastionWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bastion.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BastionWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
