defmodule Bastion.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        BastionWeb.Telemetry,
        Bastion.Repo,
        {DNSCluster, query: Application.get_env(:bastion, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Bastion.PubSub},
        BastionWeb.Presence,
        {Oban, Application.fetch_env!(:bastion, Oban)},
        {Task.Supervisor, name: Bastion.TaskSupervisor},
        Bastion.LoginCodes
      ] ++
        telegram() ++
        [
          # Start to serve requests, typically the last entry
          BastionWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Bastion.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp telegram,
    do: if(Bastion.Telegram.polling?(), do: [Bastion.Telegram.Server], else: [])

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BastionWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
