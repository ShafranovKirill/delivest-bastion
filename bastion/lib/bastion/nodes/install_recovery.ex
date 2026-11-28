defmodule Bastion.Nodes.InstallRecovery do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(state) do
    send(self(), :recover)
    {:ok, state}
  end

  @impl true
  def handle_info(:recover, state) do
    Bastion.Nodes.SshInstaller.cleanup_stale_credentials()

    try do
      Bastion.Nodes.recover_interrupted_installs()
    rescue
      Postgrex.Error -> :ok
    end

    {:noreply, state}
  end
end
