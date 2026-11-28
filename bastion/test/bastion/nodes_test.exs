defmodule Bastion.NodesTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.Nodes
  alias Bastion.Nodes.{MetricSample, Operation}

  test "registration is one-time and node credentials can be replaced without affecting another node" do
    {:ok, first, token} = Nodes.create_node("first")
    {:ok, second, other_token} = Nodes.create_node("second")

    assert {:ok, registered, credential} = Nodes.register(token, 1)
    assert registered.id == first.id
    assert {:error, :invalid_token} = Nodes.register(token, 1)
    assert {:ok, _} = Nodes.authenticate(first.id, credential)
    assert {:ok, _} = Nodes.authenticate_credential(credential)

    assert {:ok, _node, other_credential} = Nodes.register(other_token, 1)
    assert {:ok, _} = Nodes.revoke(registered)
    assert {:error, :unauthorized} = Nodes.authenticate(first.id, credential)
    assert {:ok, _} = Nodes.authenticate(second.id, other_credential)

    {:ok, _, replacement} = Nodes.reset_registration(Nodes.get_node(first.id))
    assert {:ok, _, new_credential} = Nodes.register(replacement, 1)
    assert {:ok, _} = Nodes.authenticate(first.id, new_credential)
  end

  test "two placements reserve independent ports and commands keep their selected target" do
    first = instance_fixture()
    {:ok, node, _token} = Nodes.create_node("pilot")
    second_id = Ecto.UUID.generate()

    assert {:error, :legacy_conversion_out_of_scope} =
             Nodes.create_placement(first.id, node.id, "pilot-a", 18080)

    first_id = Ecto.UUID.generate()

    {:ok, first_placement} =
      Nodes.prepare_instance(node.id, first_id, "First", %{}, "pilot-a", 18080)

    assert {:error, _} =
             Nodes.prepare_instance(node.id, second_id, "Second", %{}, "pilot-b", 18080)

    {:ok, second_placement} =
      Nodes.prepare_instance(node.id, second_id, "Second", %{}, "pilot-b", 18081)

    assert first_placement.revision == 1
    assert second_placement.revision == 1
    assert {:error, :already_placed} = Nodes.create_placement(first_id, node.id, "again", 18082)

    assert {:ok, renamed} = Nodes.rename_instance(first_id, "New display name")
    assert renamed.id == first_id
    assert Nodes.placement_for(first_id).project_name == "pilot-a"

    {:ok, stop} = Nodes.queue(first_id, "stop", "admin")
    assert stop.instance_id == first_id
    assert stop.placement_revision == first_placement.revision
    assert Nodes.command_payload(stop).node_id == node.id
    assert {:error, :busy} = Nodes.queue(first_id, "start", "admin")
    assert {:ok, _} = Nodes.queue(second_id, "status", "admin")

    assert {:error, :invalid_action_or_args} =
             Nodes.queue(first_id, "stop", "admin", %{"secret" => "bad"})

    assert {:error, :managed_by_node} =
             Bastion.Instances.send_command(Bastion.Instances.get_instance(first_id), "stop")

    assert {:ok, %{status: "running"}} =
             Nodes.update_operation(node.id, stop.id, "command_ack", %{})

    assert {:ok, %{status: "ok"}} =
             Nodes.update_operation(node.id, stop.id, "command_result", %{
               "status" => "ok",
               "result" => %{}
             })

    assert {:ok, %{status: "ok"}} =
             Nodes.update_operation(node.id, stop.id, "command_result", %{
               "status" => "error",
               "result" => %{}
             })

    assert {:ok, _} = Nodes.queue(first_id, "start", "admin")
  end

  test "reconnect replays the same ID, stale placement cannot mutate observed state" do
    {:ok, node, _} = Nodes.create_node("pilot")
    instance_id = Ecto.UUID.generate()
    {:ok, placement} = Nodes.prepare_instance(node.id, instance_id, "Pilot", %{}, "pilot", 18080)
    {:ok, operation} = Nodes.queue(instance_id, "stop", "admin")
    assert [%Operation{id: id}] = Nodes.pending_operations(node.id)
    assert id == operation.id

    heartbeat = %{
      "sample_id" => "sample-1",
      "sampled_at" => "2026-11-28T10:00:00Z",
      "version" => "0.1.0",
      "metrics" => %{"cpu" => 12},
      "instances" => [
        %{"instance_id" => instance_id, "placement_revision" => 1, "status" => "stopped"}
      ]
    }

    assert :ok = Nodes.record_heartbeat(node.id, heartbeat)
    assert :ok = Nodes.record_heartbeat(node.id, heartbeat)
    assert Repo.aggregate(MetricSample, :count) == 1
    assert Nodes.placement_for(instance_id).observed_state == "stopped"

    assert :ok =
             Nodes.record_heartbeat(node.id, %{
               heartbeat
               | "sample_id" => "old",
                 "sampled_at" => "2026-11-28T09:00:00Z",
                 "instances" => [
                   %{
                     "instance_id" => instance_id,
                     "placement_revision" => 1,
                     "status" => "running"
                   }
                 ]
             })

    assert Nodes.placement_for(instance_id).observed_state == "stopped"

    placement |> Ecto.Changeset.change(state: "retired") |> Repo.update!()
    assert Nodes.pending_operations(node.id) == []

    assert {:error, :stale_placement} =
             Nodes.update_operation(node.id, operation.id, "command_result", %{"status" => "ok"})

    assert {:error, :invalid_heartbeat} = Nodes.record_heartbeat(node.id, %{"sampled_at" => nil})
  end

  test "managed site health uses independent public check when Agent has no heartbeat" do
    {:ok, node, _} = Nodes.create_node("pilot")
    instance_id = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, instance_id, "Pilot", %{}, "pilot", 18080)
    managed = Bastion.Instances.get_instance(instance_id)

    assert Bastion.Health.evaluate(managed).level == :offline

    {:ok, checked} =
      Bastion.Instances.update_checks(
        managed,
        %{"site" => %{"ok" => false, "status" => 503}},
        :down
      )

    assert Bastion.Health.evaluate(checked).level == :down
  end

  test "a registered node is ready only after a fresh dependency report" do
    {:ok, node, token} = Nodes.create_node("Pilot")
    {:ok, _, _credential} = Nodes.register(token, 1)

    base = %{
      "sample_id" => "infra-1",
      "sampled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "version" => "0.1.0",
      "metrics" => %{},
      "instances" => []
    }

    assert :ok = Nodes.record_heartbeat(node.id, base)
    refute Nodes.ready?(Nodes.get_node(node.id))

    assert :ok =
             Nodes.record_heartbeat(
               node.id,
               Map.merge(
                 base,
                 %{
                   "sample_id" => "infra-2",
                   "infrastructure" => %{"ready" => true, "checks" => %{"docker" => true}}
                 }
               )
             )

    assert Nodes.ready?(Nodes.get_node(node.id))
    assert :ok = Nodes.record_heartbeat(node.id, Map.merge(base, %{"sample_id" => "infra-3"}))
    refute Nodes.ready?(Nodes.get_node(node.id))
  end
end
