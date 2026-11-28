defmodule Bastion.ManagedMoveTest do
  use Bastion.DataCase, async: false

  alias Bastion.{ManagedMove, Nodes, Repo}
  alias Bastion.Domains.{Binding, Domain}
  alias Bastion.Instances.Instance
  alias Bastion.Nodes.Placement
  alias Bastion.Snapshots.Snapshot

  def check(_instance, _node), do: :ok

  setup do
    old = Application.get_env(:bastion, :move_probe)
    Application.put_env(:bastion, :move_probe, __MODULE__)

    on_exit(fn ->
      if old,
        do: Application.put_env(:bastion, :move_probe, old),
        else: Application.delete_env(:bastion, :move_probe)
    end)
  end

  test "planned move reserves a new revision and adopts only a fresh restored target" do
    source = ready_node("source", "192.0.2.10")
    target = ready_node("target", "192.0.2.20")
    id = Ecto.UUID.generate()

    hosts = %{
      "site" => "shop.example.com",
      "api" => "api.example.com",
      "media" => "media.example.com"
    }

    {:ok, original} =
      Nodes.prepare_instance(source.id, id, "Shop", hosts, "source-project", 18080)

    bind_hosts(id, hosts)

    {:ok, stopped} = Nodes.queue(id, "stop", "admin")

    assert {:ok, _} =
             Nodes.update_operation(source.id, stopped.id, "command_result", %{
               "status" => "ok",
               "result" => %{"fenced" => true}
             })

    original
    |> Ecto.Changeset.change(observed_state: "stopped", observed_at: DateTime.utc_now())
    |> Repo.update!()

    snapshot_id = Ecto.UUID.generate()
    {:ok, backup_op} = Nodes.queue(id, "backup", "admin", %{"backup_id" => snapshot_id})

    assert {:ok, _} =
             Nodes.update_operation(source.id, backup_op.id, "command_result", %{
               "status" => "ok",
               "result" => %{}
             })

    now = DateTime.utc_now()

    Repo.insert!(%Snapshot{
      id: snapshot_id,
      instance_id: id,
      node_operation_id: backup_op.id,
      instance_name: "Shop",
      kind: "full",
      status: "ok",
      key: "test/archive",
      checksum: String.duplicate("a", 64),
      release_compatibility: %{"release_version" => "1.0.0"},
      integrity_checked_at: now,
      finished_at: now
    })

    assert {:ok, move} = ManagedMove.reserve(id, target.id, 18081, "planned", "", "admin")

    assert {:error, :local_operation} =
             Nodes.update_operation(source.id, move.id, "command_result", %{
               "status" => "ok",
               "result" => %{}
             })

    info = ManagedMove.instructions(move)
    assert info.target.revision == 2
    assert info.target.project_name == "delivest-" <> String.replace(id, "-", "")
    assert info.snapshot_id == snapshot_id
    assert {:ok, encoded} = Base.decode64(info.prepare_base64)
    assert %{"operation_id" => operation_id, "bindings" => bindings} = Jason.decode!(encoded)
    assert operation_id == move.id
    assert Enum.sort(Enum.map(bindings, & &1["purpose"])) == ~w(api media site)

    assert {:error, :target_not_ready} = ManagedMove.confirm(move.id, "admin")

    observation = %{
      "sample_id" => "target-ready",
      "sampled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "version" => "0.1.0",
      "metrics" => %{},
      "infrastructure" => %{"ready" => true},
      "instances" => [
        %{
          "instance_id" => id,
          "placement_revision" => 2,
          "status" => "running",
          "release_version" => "1.0.0",
          "transfer_ready" => move.id
        }
      ]
    }

    premature =
      update_in(observation, ["instances", Access.at(0)], &Map.delete(&1, "transfer_ready"))

    assert :ok = Nodes.record_heartbeat(target.id, premature)
    assert {:error, :target_not_ready} = ManagedMove.confirm(move.id, "admin")

    assert :ok = Nodes.record_heartbeat(target.id, %{observation | "sample_id" => "prepared"})

    assert {:error, :target_already_observed} =
             ManagedMove.cancel(
               move.id,
               "admin",
               "target_removed_and_fenced",
               "Checked target state"
             )

    degraded_at = DateTime.add(DateTime.utc_now(), 1, :second)

    degraded =
      observation
      |> Map.put("sample_id", "degraded")
      |> Map.put("sampled_at", DateTime.to_iso8601(degraded_at))
      |> put_in(["instances", Access.at(0), "status"], "degraded")

    assert :ok = Nodes.record_heartbeat(target.id, degraded)
    assert :ok = Nodes.record_heartbeat(target.id, %{observation | "sample_id" => "late-ready"})
    assert {:error, :target_not_ready} = ManagedMove.confirm(move.id, "admin")

    ready_again =
      observation
      |> Map.put("sample_id", "ready-again")
      |> Map.put("sampled_at", DateTime.to_iso8601(DateTime.add(degraded_at, 1, :second)))

    assert :ok = Nodes.record_heartbeat(target.id, ready_again)
    assert {:ok, _} = ManagedMove.confirm(move.id, "admin")
    assert Nodes.placement_for(id).node_id == target.id
    assert Repo.get!(Placement, original.id).state == "retired"
    assert Repo.get!(Instance, id).hosts == hosts
    assert Repo.get!(Instance, id).desired_state == "running"
    assert Repo.get!(Instance, id).desired_release == "1.0.0"

    for binding <- Repo.all(Binding), binding.instance_id == id do
      assert binding.expected_records == %{"addresses" => ["192.0.2.20"]}

      assert binding.observed_records == %{
               "addresses" => ["192.0.2.20"],
               "expected" => ["192.0.2.20"]
             }

      assert binding.owned_records == %{}
    end
  end

  test "reservation can be cancelled before target has been observed" do
    source = ready_node("source", "192.0.2.10")
    target = ready_node("target", "192.0.2.20")
    id = Ecto.UUID.generate()

    hosts = %{
      "site" => "shop.example.com",
      "api" => "api.example.com",
      "media" => "media.example.com"
    }

    {:ok, _} = Nodes.prepare_instance(source.id, id, "Shop", hosts, "source-project", 18080)
    bind_hosts(id, hosts)

    snapshot_id = Ecto.UUID.generate()
    {:ok, backup_op} = Nodes.queue(id, "backup", "admin", %{"backup_id" => snapshot_id})

    assert {:ok, _} =
             Nodes.update_operation(source.id, backup_op.id, "command_result", %{
               "status" => "ok",
               "result" => %{}
             })

    now = DateTime.utc_now()

    Repo.insert!(%Snapshot{
      id: snapshot_id,
      instance_id: id,
      node_operation_id: backup_op.id,
      instance_name: "Shop",
      kind: "full",
      status: "ok",
      key: "test/archive",
      checksum: String.duplicate("a", 64),
      integrity_checked_at: now,
      finished_at: now
    })

    source
    |> Ecto.Changeset.change(last_seen_at: DateTime.add(now, -600))
    |> Repo.update!()

    assert {:ok, move} =
             ManagedMove.reserve(
               id,
               target.id,
               18081,
               "disaster",
               "Externally fenced source",
               "admin"
             )

    assert {:error, :confirmation_required} =
             ManagedMove.cancel(move.id, "admin", "target_removed_and_fenced", "            ")

    assert {:ok, _} =
             ManagedMove.cancel(
               move.id,
               "admin",
               "target_removed_and_fenced",
               "Checked empty target state"
             )

    assert ManagedMove.pending(id) == nil
    assert Repo.get!(Placement, move.args["target_placement_id"]).state == "retired"
  end

  defp ready_node(name, address) do
    {:ok, _node, token} = Nodes.create_node(name)
    {:ok, node, _credential} = Nodes.register(token, 1)

    node
    |> Ecto.Changeset.change(
      last_seen_at: DateTime.utc_now(),
      infrastructure: %{"ready" => true},
      public_ipv4: address
    )
    |> Repo.update!()
  end

  defp bind_hosts(id, hosts) do
    Enum.each(hosts, fn {purpose, hostname} ->
      domain = Repo.insert!(%Domain{hostname: hostname, dns_mode: "external", state: "connected"})

      Repo.insert!(%Binding{
        domain_id: domain.id,
        instance_id: id,
        purpose: purpose,
        state: "connected"
      })
    end)
  end
end
