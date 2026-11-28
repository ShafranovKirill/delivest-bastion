defmodule Bastion.FleetTest do
  use Bastion.DataCase, async: true

  alias Bastion.{Fleet, Instances, NodeMaintenance, Nodes}
  alias Bastion.Nodes.Operation

  test "a connected node with two confirmed outages gets one incident and keeps it in history" do
    {node, first, second} = fleet()
    assert "Высокая загрузка CPU" in Fleet.node_resources(node).warnings
    fail_site(first)
    fail_site(second)

    Fleet.reconcile()
    Fleet.reconcile()

    assert [incident] = Fleet.recent_incidents()
    assert incident.kind == "shared_outage"
    assert incident.node_id == node.id
    assert incident.affected == %{first.id => first.name, second.id => second.name}

    {:ok, _} = Instances.update_checks(first, checks(true), :ok)
    Fleet.reconcile()
    assert [closed] = Fleet.recent_incidents()
    assert closed.id == incident.id
    assert closed.ended_at
  end

  test "site status is independent of heartbeat and planned stop takes precedence" do
    {node, first, _} = fleet()
    {:ok, first} = Instances.update_checks(first, checks(true), :ok)

    node
    |> change(last_seen_at: DateTime.add(DateTime.utc_now(), -120))
    |> Repo.update!()

    assert %{site: :ok, api: :ok, connected: false, backup: :missing} = Fleet.instance(first)
    Fleet.reconcile()
    assert [incident] = Fleet.recent_incidents()
    assert incident.kind == "management"

    assert Fleet.public_state(%{first | desired_state: "stopped"}, "site") == :stopped
    assert Fleet.public_state(%{first | checked_at: nil}, "site") == :unknown
  end

  test "maintenance rejects new placements and records the actor without stopping existing ones" do
    {node, first, _} = fleet()

    assert {:ok, %{maintenance: true}} = NodeMaintenance.set(node.id, true, "owner")
    assert {:ok, %{maintenance: true}} = NodeMaintenance.set(node.id, true, "owner")

    assert {:error, :node_in_maintenance} =
             Nodes.prepare_instance(node.id, Ecto.UUID.generate(), "New", %{}, "new", 18090)

    assert %Operation{requested_by: "owner", result: %{"maintenance" => true}} =
             Repo.one(from o in Operation, where: o.action == "node_maintenance")

    assert Instances.get_instance(first.id).desired_state == "running"
    assert Nodes.placement_for(first.id).node_id == node.id
    assert {:ok, %{maintenance: false}} = NodeMaintenance.set(node.id, false, "owner")
  end

  defp fleet do
    {:ok, node, token} = Nodes.create_node("Pilot")
    {:ok, _, _credential} = Nodes.register(token, 1)

    first = make_instance(node, "First", "first", 18080)
    second = make_instance(node, "Second", "second", 18081)

    :ok =
      Nodes.record_heartbeat(node.id, %{
        "sample_id" => "fleet",
        "sampled_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "version" => "1.0.0",
        "metrics" => %{"cpu_percent" => 99},
        "infrastructure" => %{"ready" => true},
        "instances" => []
      })

    {Nodes.get_node(node.id), first, second}
  end

  defp make_instance(node, name, project, port) do
    id = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, id, name, %{}, project, port)

    id |> Instances.get_instance() |> change(desired_state: "running") |> Repo.update!()
  end

  defp fail_site(instance), do: Instances.update_checks(instance, checks(false), :down)
  defp checks(up), do: %{"site" => %{"ok" => up}, "api" => %{"ok" => true}}
end
