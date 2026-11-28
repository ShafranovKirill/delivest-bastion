defmodule Bastion.ManagedRolloutTest do
  use Bastion.DataCase, async: false

  alias Bastion.{ManagedRollout, ManagedUpdates, Nodes, Repo}
  alias Bastion.Nodes.Operation

  @release %{
    version: "9.0.0",
    url:
      "https://github.com/ShafranovKirill/delivest/releases/download/v9.0.0/delivest-deploy-9.0.0.tar.gz",
    sha256: String.duplicate("a", 64)
  }

  test "one pinned update keeps its ID across duplicate requests and records the installed version" do
    {node, instance_id} = installation("first", 18080)

    assert {:ok, first} = ManagedUpdates.start(instance_id, "admin", "telegram:1:2:a", @release)
    assert {:ok, again} = ManagedUpdates.start(instance_id, "admin", "telegram:1:2:a", @release)
    assert first.id == again.id
    assert first.action == "instance_update"
    assert Nodes.command_payload(first).args == ManagedUpdates.args(@release)

    assert {:error, :busy} =
             ManagedUpdates.start(instance_id, "admin", "telegram:1:2:b", @release)

    assert {:error, :invalid_update_result} =
             Nodes.update_operation(node.id, first.id, "command_result", %{
               "status" => "ok",
               "result" => %{"release_version" => "8.0.0"}
             })

    assert {:ok, %Operation{status: "ok"}} =
             Nodes.update_operation(node.id, first.id, "command_result", %{
               "status" => "ok",
               "result" => %{"release_version" => "9.0.0"}
             })

    assert Nodes.placement_for(instance_id).observed_release == "9.0.0"
    assert Bastion.Instances.get_instance(instance_id).desired_release == "9.0.0"
  end

  test "rollout freezes its canary and pauses before the second installation on failure" do
    {first_node, first_id} = installation("first", 18080)
    {_second_node, second_id} = installation("second", 18081)

    assert {:ok, rollout} =
             ManagedRollout.start([second_id, first_id], first_id, "admin", @release)

    assert Enum.map(Enum.sort_by(rollout.items, & &1.position), & &1.instance_id) == [
             first_id,
             second_id
           ]

    assert :ok = ManagedRollout.advance(rollout.id)

    current = ManagedRollout.get(rollout.id)
    first_item = Enum.find(current.items, &(&1.instance_id == first_id))
    assert first_item.status == "running"
    assert Enum.find(current.items, &(&1.instance_id == second_id)).status == "pending"

    assert {:ok, _} =
             Nodes.update_operation(first_node.id, first_item.operation_id, "command_result", %{
               "status" => "error",
               "result" => %{"reason" => "migration failed"}
             })

    assert :ok = ManagedRollout.advance(rollout.id)
    paused = ManagedRollout.get(rollout.id)
    assert paused.status == "paused"
    assert Enum.find(paused.items, &(&1.instance_id == second_id)).operation_id == nil
  end

  test "rollout pauses when its first installation already has a command" do
    {_node, first_id} = installation("busy", 18082)
    assert {:ok, rollout} = ManagedRollout.start([first_id], first_id, "admin", @release)
    assert {:ok, _} = Nodes.queue(first_id, "status", "admin")

    assert :ok = ManagedRollout.advance(rollout.id)
    assert ManagedRollout.get(rollout.id).status == "paused"

    busy = List.first(Nodes.operations_for(first_id))

    assert {:ok, _} =
             Nodes.update_operation(busy.node_id, busy.id, "command_result", %{
               "status" => "ok",
               "result" => %{}
             })

    assert {:ok, _} = ManagedRollout.resume(rollout.id, "admin")
    assert :ok = ManagedRollout.advance(rollout.id)
    current = ManagedRollout.get(rollout.id)
    assert current.status == "running"
    assert hd(current.items).operation_id != busy.id
  end

  test "rollout advances after success and never queues a successful item again" do
    {first_node, first_id} = installation("canary", 18083)
    {second_node, second_id} = installation("next", 18084)

    assert {:ok, rollout} =
             ManagedRollout.start([first_id, second_id], first_id, "admin", @release)

    assert :ok = ManagedRollout.advance(rollout.id)
    first_operation = hd(Nodes.operations_for(first_id))
    assert Nodes.operations_for(second_id) == []

    assert {:ok, _} =
             Nodes.update_operation(first_node.id, first_operation.id, "command_result", %{
               "status" => "ok",
               "result" => %{"release_version" => "9.0.0"}
             })

    assert :ok = ManagedRollout.advance(rollout.id)
    second_operation = hd(Nodes.operations_for(second_id))
    assert second_operation.id != first_operation.id

    assert {:ok, _} =
             Nodes.update_operation(second_node.id, second_operation.id, "command_result", %{
               "status" => "ok",
               "result" => %{"release_version" => "9.0.0"}
             })

    assert :ok = ManagedRollout.advance(rollout.id)
    assert ManagedRollout.get(rollout.id).status == "done"
    assert length(Nodes.operations_for(first_id)) == 1
    assert length(Nodes.operations_for(second_id)) == 1
  end

  test "heartbeat preserves the last release when absent or stale" do
    {node, instance_id} = installation("observed", 18085)
    now = DateTime.utc_now()

    payload = %{
      "sample_id" => "first",
      "sampled_at" => DateTime.to_iso8601(now),
      "version" => "0.1.0",
      "metrics" => %{},
      "instances" => [
        %{"instance_id" => instance_id, "placement_revision" => 1, "status" => "running"}
      ]
    }

    assert :ok = Nodes.record_heartbeat(node.id, payload)
    assert Nodes.placement_for(instance_id).observed_release == "1.0.0"

    updated = put_in(payload, ["instances", Access.at(0), "release_version"], "2.0.0")
    assert :ok = Nodes.record_heartbeat(node.id, %{updated | "sample_id" => "second"})
    assert Nodes.placement_for(instance_id).observed_release == "2.0.0"

    old = %{
      updated
      | "sample_id" => "old",
        "sampled_at" => DateTime.to_iso8601(DateTime.add(now, -10))
    }

    old = put_in(old, ["instances", Access.at(0), "release_version"], "1.0.0")
    assert :ok = Nodes.record_heartbeat(node.id, old)
    assert Nodes.placement_for(instance_id).observed_release == "2.0.0"

    invalid = put_in(updated, ["instances", Access.at(0), "release_version"], "bad")
    assert {:error, :invalid_heartbeat} = Nodes.record_heartbeat(node.id, invalid)

    guard = [%{"service" => "server", "state" => "tripped", "restarts" => 3}]
    guarded = put_in(updated, ["instances", Access.at(0), "restart_guard"], guard)
    assert :ok = Nodes.record_heartbeat(node.id, %{guarded | "sample_id" => "guard"})
    assert Nodes.placement_for(instance_id).restart_guard == guard

    malformed =
      put_in(guarded, ["instances", Access.at(0), "restart_guard"], [
        %{"service" => "server", "state" => "unknown"}
      ])

    assert {:error, :invalid_heartbeat} = Nodes.record_heartbeat(node.id, malformed)
  end

  test "manual pause lets an in-flight command finish without dispatching the next" do
    {first_node, first_id} = installation("first-pause", 18086)
    {_second_node, second_id} = installation("second-pause", 18087)

    assert {:ok, rollout} =
             ManagedRollout.start([first_id, second_id], first_id, "admin", @release)

    assert :ok = ManagedRollout.advance(rollout.id)
    first = hd(Nodes.operations_for(first_id))

    assert {:ok, _} = ManagedRollout.pause(rollout.id, "admin")
    assert :ok = ManagedRollout.advance(rollout.id)

    assert {:ok, _} =
             Nodes.update_operation(first_node.id, first.id, "command_result", %{
               "status" => "ok",
               "result" => %{"release_version" => "9.0.0"}
             })

    assert :ok = ManagedRollout.reconcile_paused()

    assert Enum.find(ManagedRollout.get(rollout.id).items, &(&1.instance_id == first_id)).status ==
             "ok"

    assert Nodes.operations_for(second_id) == []

    assert {:ok, _} = ManagedRollout.resume(rollout.id, "admin")
    assert :ok = ManagedRollout.advance(rollout.id)
    assert length(Nodes.operations_for(second_id)) == 1
  end

  defp installation(name, port) do
    {:ok, node, _} = Nodes.create_node(name)
    id = Ecto.UUID.generate()
    {:ok, placement} = Nodes.prepare_instance(node.id, id, name, %{}, name, port)

    placement
    |> Ecto.Changeset.change(observed_state: "running", observed_release: "1.0.0")
    |> Repo.update!()

    {node, id}
  end
end
