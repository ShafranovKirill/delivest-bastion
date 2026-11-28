defmodule Bastion.Domains.DnsPoller do
  use GenServer
  import Ecto.Query

  alias Bastion.Domains.Binding
  alias Bastion.Repo

  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @impl true
  def init(state) do
    schedule()
    {:ok, state}
  end

  @impl true
  def handle_info(:poll, state) do
    Task.Supervisor.start_child(Bastion.TaskSupervisor, &poll/0)
    schedule()
    {:noreply, state}
  end

  def poll do
    Repo.all(
      from b in Binding,
        as: :binding,
        where: b.state == "waiting_dns",
        where:
          not exists(
            from o in Bastion.Nodes.Operation,
              where:
                o.instance_id == parent_as(:binding).instance_id and o.action == "instance_create" and
                  o.status != "ok"
          ),
        select: b.id,
        limit: 100
    )
    |> Enum.each(fn id -> Bastion.Domains.request_prepare(id, nil, "system") end)

    Bastion.ManagedInstances.advance_pending()
  end

  defp schedule, do: Process.send_after(self(), :poll, 60_000)
end
