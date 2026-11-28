defmodule Bastion.ManagedSnapshotsTest do
  use Bastion.DataCase, async: false

  alias Bastion.{ManagedSnapshots, Nodes, Repo}
  alias Bastion.Snapshots.Snapshot

  setup do
    Application.put_env(:bastion, :offsite_storage,
      url: "https://offsite.test",
      bucket: "offsite",
      access_key: "key",
      secret_key: "secret"
    )

    System.put_env("MANAGED_BACKUP_ENCRYPTION_KEY", String.duplicate("x", 40))

    on_exit(fn ->
      Application.delete_env(:bastion, :offsite_storage)
      System.delete_env("MANAGED_BACKUP_ENCRYPTION_KEY")
    end)

    :ok
  end

  test "managed snapshot keeps upload credentials out of the operation and refreshes them for replay" do
    {:ok, node, token} = Nodes.create_node("pilot")
    {:ok, _, _} = Nodes.register(token, 1)

    :ok =
      Nodes.record_heartbeat(node.id, %{
        "sample_id" => Ecto.UUID.generate(),
        "sampled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "version" => "0.2.0",
        "metrics" => %{},
        "instances" => [],
        "infrastructure" => %{"ready" => true}
      })

    id = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, id, "Pilot", %{}, "pilot", 18080)
    instance = Bastion.Instances.get_instance(id)

    assert {:ok, snapshot} = ManagedSnapshots.start(instance, "owner")
    operation = Repo.get!(Nodes.Operation, snapshot.node_operation_id)
    assert operation.args == %{"backup_id" => snapshot.id}
    assert {:error, :busy} = ManagedSnapshots.start(instance, "owner")

    payload = Nodes.command_payload(operation)
    assert payload.args["backup_id"] == snapshot.id
    assert String.starts_with?(payload.args["upload_url"], "http")

    assert {:ok, %Snapshot{id: sid}} =
             ManagedSnapshots.authorize_upload(snapshot.id, payload.args["token"])

    assert sid == snapshot.id
    refute inspect(operation) =~ payload.args["token"]

    snapshot
    |> Ecto.Changeset.change(status: "ok", checksum: String.duplicate("a", 64))
    |> Repo.update!()

    replay = Nodes.command_payload(operation)
    assert replay.args["token"] != ""
    assert {:ok, _} = ManagedSnapshots.authorize_upload(snapshot.id, replay.args["token"])
  end

  test "offsite storage is mandatory for managed copies" do
    Application.delete_env(:bastion, :offsite_storage)

    assert {:error, :offsite_storage_unavailable} =
             ManagedSnapshots.start(%Bastion.Instances.Instance{transport: "node"})
  end

  test "upload is idempotent for the same archive and rejects changed contents" do
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000)
      send(test_pid, {:stored, body})
      Plug.Conn.send_resp(conn, 200, "")
    end)

    id = Ecto.UUID.generate()
    node = ready_node()
    instance_id = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, instance_id, "Pilot", %{}, "pilot", 18080)
    {:ok, operation} = Nodes.queue_deferred(instance_id, "backup", "owner", %{"backup_id" => id})

    snapshot =
      Repo.insert!(%Snapshot{
        id: id,
        instance_id: instance_id,
        instance_name: "Pilot",
        key: "managed/test.enc",
        node_operation_id: operation.id
      })

    directory = Path.join(System.tmp_dir!(), "bastion-managed-test-#{id}")

    try do
      first = archive(directory, instance_id, "first")
      assert {:ok, saved} = ManagedSnapshots.store(snapshot, first)
      assert saved.status == "ok"
      assert is_binary(saved.checksum)
      assert_receive {:stored, ciphertext}
      refute ciphertext =~ "first"

      assert {:ok, repeated} = ManagedSnapshots.store(saved, first)
      assert repeated.id == saved.id
      refute_receive {:stored, _}

      changed = archive(directory, instance_id, "second")
      assert {:error, :backup_digest_conflict} = ManagedSnapshots.store(saved, changed)
      refute_receive {:stored, _}
    after
      File.rm_rf!(directory)
    end
  end

  test "confirmed deletion requires stopped placement and released domains, then retires only its placement" do
    {:ok, node, token} = Nodes.create_node("deletion-pilot")
    {:ok, _, _} = Nodes.register(token, 1)
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, first, "First", %{}, "first", 18080)
    {:ok, _} = Nodes.prepare_instance(node.id, second, "Second", %{}, "second", 18081)

    assert {:error, :instance_mismatch} =
             Nodes.queue(first, "instance_delete", "owner", %{"confirm_instance_id" => second})

    assert {:error, :not_confirmed_stopped} =
             Nodes.queue(first, "instance_delete", "owner", %{"confirm_instance_id" => first})

    {:ok, stop} = Nodes.queue(first, "stop", "owner")

    {:ok, _} =
      Nodes.update_operation(node.id, stop.id, "command_result", %{
        "status" => "ok",
        "result" => %{}
      })

    :ok =
      Nodes.record_heartbeat(node.id, %{
        "sample_id" => Ecto.UUID.generate(),
        "sampled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "version" => "0.2.0",
        "metrics" => %{},
        "instances" => [
          %{"instance_id" => first, "placement_revision" => 1, "status" => "stopped"}
        ],
        "infrastructure" => %{"ready" => true}
      })

    {:ok, domain} =
      Bastion.Domains.create_domain(%{
        "hostname" => "delete.example.test",
        "dns_mode" => "external"
      })

    {:ok, binding} = Bastion.Domains.reserve(domain.id, first, "site", true)

    assert {:error, :active_domain_bindings} =
             Nodes.queue(first, "instance_delete", "owner", %{"confirm_instance_id" => first})

    assert {:ok, _} = Bastion.Domains.release(binding.id)

    assert {:ok, operation} =
             Nodes.queue(first, "instance_delete", "owner", %{"confirm_instance_id" => first})

    assert {:error, :busy} = Nodes.queue(first, "start", "owner")

    assert {:error, :invalid_delete_result} =
             Nodes.update_operation(node.id, operation.id, "command_result", %{
               "status" => "ok",
               "result" => %{"deleted" => true, "instance_id" => second}
             })

    payload = %{"status" => "ok", "result" => %{"deleted" => true, "instance_id" => first}}

    assert {:ok, %{status: "ok"}} =
             Nodes.update_operation(node.id, operation.id, "command_result", payload)

    assert is_nil(Nodes.placement_for(first))
    assert Nodes.placement_for(second)

    assert {:ok, %{status: "ok"}} =
             Nodes.update_operation(node.id, operation.id, "command_result", payload)

    assert {:error, :placement_not_found} = Nodes.queue(first, "start", "owner")
  end

  test "new full copy preserves its predecessor until restore verification is recorded" do
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      send(test_pid, {:storage, conn.method, conn.request_path})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    {:ok, node, _} = Nodes.create_node("retention")
    instance_id = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, instance_id, "Pilot", %{}, "pilot", 18080)

    previous = stored_full(instance_id, "previous", DateTime.add(DateTime.utc_now(), -86_400))
    current = stored_full(instance_id, "current", DateTime.utc_now())
    assert Repo.get!(Snapshot, previous.id).status == "ok"
    refute_receive {:storage, "DELETE", _}

    assert {:error, :restore_evidence_required} =
             ManagedSnapshots.confirm_restore(current.id, "owner", "")

    assert {:ok, checked} =
             ManagedSnapshots.confirm_restore(current.id, "owner", "isolated drill #42")

    assert checked.restore_checked_by == "owner"
    assert checked.restore_evidence == "isolated drill #42"
    assert checked.restore_checked_at
    assert Repo.get!(Snapshot, previous.id).status == "obsolete"
    assert_receive {:storage, "DELETE", _}
    assert Repo.get!(Snapshot, current.id).status == "ok"
    assert ManagedSnapshots.last_restore_checked(instance_id).id == current.id
  end

  test "newer verified restore point cannot be replaced by older approval and failed cleanup can retry" do
    Req.Test.stub(Bastion.Http, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    {:ok, node, _} = Nodes.create_node("retention-retry")
    instance_id = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, instance_id, "Pilot", %{}, "pilot", 18080)
    old = stored_full(instance_id, "old", DateTime.add(DateTime.utc_now(), -86_400))
    fresh = stored_full(instance_id, "fresh", DateTime.utc_now())

    assert {:ok, checked} =
             ManagedSnapshots.confirm_restore(fresh.id, "owner", "isolated drill #99")

    assert checked.error == "не удалось очистить прежние копии"
    assert Repo.get!(Snapshot, old.id).status == "ok"

    assert {:error, :newer_restore_verified} =
             ManagedSnapshots.confirm_restore(old.id, "owner", "older drill #88")

    Req.Test.stub(Bastion.Http, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)

    assert {:ok, repeated} =
             ManagedSnapshots.confirm_restore(fresh.id, "another owner", "ignored retry")

    assert repeated.error == nil
    assert repeated.restore_checked_by == "owner"
    assert Repo.get!(Snapshot, old.id).status == "obsolete"
  end

  defp stored_full(instance_id, label, at) do
    id = Ecto.UUID.generate()
    {:ok, operation} = Nodes.queue_deferred(instance_id, "backup", "owner", %{"backup_id" => id})
    operation |> Ecto.Changeset.change(status: "ok") |> Repo.update!()

    %Snapshot{
      id: id,
      instance_id: instance_id,
      instance_name: "Pilot",
      node_operation_id: operation.id,
      key: "managed/#{label}.enc",
      status: "ok",
      checksum: String.duplicate("a", 64),
      size: 100,
      integrity_checked_at: at,
      finished_at: at,
      inserted_at: at
    }
    |> Repo.insert!()
  end

  defp ready_node do
    {:ok, node, _} = Nodes.create_node("backup-test")
    node
  end

  defp archive(directory, id, value) do
    source = Path.join(directory, value)

    names =
      ~w(project/.package-sha256 project/.env project/docker-compose.yml project/deploy/nginx/gateway.conf.template project/release-manifest.json project/reservation.json volumes/postgres_prod_data.tar volumes/s3_data.tar volumes/public_site_state.tar volumes/instance_backups.tar)

    files =
      Map.new(names, fn name ->
        path = Path.join(source, name)
        File.mkdir_p!(Path.dirname(path))
        content = if name == "project/release-manifest.json", do: "release", else: value
        File.write!(path, content)

        {name,
         %{
           "size" => byte_size(content),
           "sha256" => :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
         }}
      end)

    manifest = %{
      "schema_version" => 1,
      "instance_id" => id,
      "project_name" => "pilot",
      "placement_revision" => 1,
      "captured_at" => "2026-11-28T00:00:00Z",
      "release_version" => "1.24.0",
      "release_manifest_sha256" => files["project/release-manifest.json"]["sha256"],
      "files" => files
    }

    File.write!(Path.join(source, "manifest.json"), Jason.encode!(manifest))
    output = Path.join(directory, "#{value}.tar.gz")

    {_, 0} =
      System.cmd("tar", ["-C", source, "-czf", output, "manifest.json", "project", "volumes"])

    output
  end
end
