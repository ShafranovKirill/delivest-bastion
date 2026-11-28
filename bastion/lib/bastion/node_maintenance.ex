defmodule Bastion.NodeMaintenance do
  import Ecto.Query

  alias Bastion.Nodes.{Node, Operation}
  alias Bastion.Repo

  def set(node_id, enabled, actor) when is_boolean(enabled) and is_binary(actor) do
    result =
      Repo.transaction(fn ->
        node = Repo.one!(from n in Node, where: n.id == ^node_id, lock: "FOR UPDATE")

        if node.maintenance == enabled do
          node
        else
          now = DateTime.utc_now()

          Repo.insert!(%Operation{
            node_id: node.id,
            action: "node_maintenance",
            requested_by: actor,
            status: "ok",
            finished_at: now,
            result: %{"maintenance" => enabled}
          })

          node |> Ecto.Changeset.change(maintenance: enabled) |> Repo.update!()
        end
      end)

    if match?({:ok, _}, result),
      do: Phoenix.PubSub.broadcast(Bastion.PubSub, "managed_nodes", :nodes_updated)

    result
  end
end
