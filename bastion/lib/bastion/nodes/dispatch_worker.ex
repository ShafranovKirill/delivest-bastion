defmodule Bastion.Nodes.DispatchWorker do
  use Oban.Worker, queue: :checks, max_attempts: 1

  @impl true
  def perform(_job) do
    Bastion.Nodes.mark_stale_unknown()

    for node <- Bastion.Nodes.list_nodes(),
        operation <- Bastion.Nodes.pending_operations(node.id) do
      Phoenix.PubSub.broadcast(
        Bastion.PubSub,
        "node_commands:#{node.id}",
        {:push_operation, operation}
      )
    end

    :ok
  end
end
