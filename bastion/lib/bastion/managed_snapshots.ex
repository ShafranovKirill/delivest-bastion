defmodule Bastion.ManagedSnapshots do
  @moduledoc "Full, off-node snapshots of installations controlled by Delivest Node."

  import Ecto.Query

  alias Bastion.{Alerts, Nodes, Repo, Snapshots, Storage}
  alias Bastion.Instances.Instance
  alias Bastion.Nodes.Operation
  alias Bastion.Snapshots.Snapshot

  @salt "managed snapshot upload"
  @max_age 7200

  def start(instance, requested_by \\ nil)

  def start(%Instance{transport: "node"} = instance, requested_by) do
    cond do
      not Storage.configured?(:offsite) -> {:error, :offsite_storage_unavailable}
      not encryption_configured?() -> {:error, :encryption_key_unavailable}
      is_nil(Nodes.placement_for(instance.id)) -> {:error, :placement_not_found}
      not Nodes.ready?(Nodes.placement_for(instance.id).node) -> {:error, :offline}
      true -> queue(instance, requested_by)
    end
  end

  def start(_, _), do: {:error, :not_managed}

  defp queue(instance, requested_by) do
    id = Ecto.UUID.generate()
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d-%H%M")

    snapshot = %Snapshot{
      id: id,
      instance_id: instance.id,
      instance_name: instance.name,
      key: "managed-snapshots/#{instance.id}/#{stamp}-#{id}.tar.gz.enc",
      requested_by: requested_by
    }

    result =
      Repo.transaction(fn ->
        snapshot =
          snapshot
          |> Ecto.Changeset.change()
          |> Ecto.Changeset.unique_constraint(:instance_id,
            name: :snapshots_one_pending_per_instance
          )
          |> Repo.insert()
          |> case do
            {:ok, value} -> value
            {:error, _} -> Repo.rollback(:busy)
          end

        operation =
          case Nodes.queue_deferred(instance.id, "backup", requested_by, %{"backup_id" => id}) do
            {:ok, value} -> value
            {:error, reason} -> Repo.rollback(reason)
          end

        snapshot =
          snapshot |> Ecto.Changeset.change(node_operation_id: operation.id) |> Repo.update!()

        {snapshot, operation}
      end)

    case result do
      {:ok, {snapshot, operation}} ->
        Nodes.dispatch_operation(operation)
        {:ok, snapshot}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delivery_args(%Operation{action: "backup", args: %{"backup_id" => id}, id: operation_id}) do
    case Snapshots.get(id) do
      %Snapshot{status: status, node_operation_id: ^operation_id}
      when status in ["pending", "ok"] ->
        %{
          "backup_id" => id,
          "upload_url" => BastionWeb.Endpoint.url() <> "/agent/backups/snapshots/#{id}",
          "token" => Phoenix.Token.sign(BastionWeb.Endpoint, @salt, id)
        }

      _ ->
        %{"backup_id" => id}
    end
  end

  def authorize_upload(id, token) when is_binary(token) do
    with %Snapshot{status: status, node_operation_id: operation_id} = snapshot <-
           Snapshots.get(id),
         true <- status in ["pending", "ok"],
         true <- not is_nil(operation_id),
         {:ok, ^id} <- Phoenix.Token.verify(BastionWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, snapshot}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize_upload(_, _), do: {:error, :unauthorized}

  def store(%Snapshot{} = snapshot, path) do
    with {:ok, manifest} <- verify(path, snapshot),
         {:ok, %{sha256: checksum, size: size}} <- Snapshots.Archive.digest(path),
         {:ok, saved} <- store_verified(snapshot, path, manifest, checksum, size) do
      broadcast(saved)
      {:ok, saved}
    else
      {:error, reason} ->
        fail_pending(snapshot.id, inspect(reason))
        {:error, reason}
    end
  end

  defp store_verified(snapshot, path, manifest, checksum, size) do
    Repo.transaction(
      fn ->
        current = Repo.one!(from s in Snapshot, where: s.id == ^snapshot.id, lock: "FOR UPDATE")

        case current do
          %Snapshot{status: "ok", checksum: ^checksum} ->
            current

          %Snapshot{status: "ok"} ->
            Repo.rollback(:backup_digest_conflict)

          %Snapshot{status: "pending"} ->
            case encrypt_and_store(current.key, path) do
              :ok ->
                {:ok, saved} = publish(current, manifest, checksum, size)
                saved

              {:error, reason} ->
                Repo.rollback(reason)
            end

          _ ->
            Repo.rollback(:backup_no_longer_pending)
        end
      end,
      timeout: 900_000
    )
  end

  defp encryption_configured? do
    case System.get_env("MANAGED_BACKUP_ENCRYPTION_KEY") do
      key when is_binary(key) and byte_size(key) >= 32 -> true
      _ -> false
    end
  end

  def fetch(%Snapshot{status: "ok"} = snapshot, path) do
    encrypted = path <> ".enc"

    try do
      with true <- encryption_configured?(),
           :ok <- Storage.download(snapshot.key, encrypted, :offsite),
           :ok <- decrypt(encrypted, path),
           {:ok, %{sha256: checksum}} <- Snapshots.Archive.digest(path),
           true <- checksum == snapshot.checksum do
        :ok
      else
        _ -> {:error, :managed_snapshot_unavailable}
      end
    after
      File.rm(encrypted)
    end
  end

  defp decrypt(encrypted, path) do
    secret = System.fetch_env!("MANAGED_BACKUP_ENCRYPTION_KEY")

    case System.cmd(
           "openssl",
           [
             "enc",
             "-d",
             "-aes-256-cbc",
             "-pbkdf2",
             "-iter",
             "200000",
             "-in",
             encrypted,
             "-out",
             path,
             "-pass",
             "env:DELIVEST_BACKUP_PASSPHRASE"
           ],
           env: [{"DELIVEST_BACKUP_PASSPHRASE", secret}],
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      _ -> {:error, :backup_decryption_failed}
    end
  end

  defp encrypt_and_store(key, path) do
    encrypted = path <> ".enc"
    secret = System.get_env("MANAGED_BACKUP_ENCRYPTION_KEY")

    try do
      case System.cmd(
             "openssl",
             [
               "enc",
               "-aes-256-cbc",
               "-pbkdf2",
               "-iter",
               "200000",
               "-salt",
               "-in",
               path,
               "-out",
               encrypted,
               "-pass",
               "env:DELIVEST_BACKUP_PASSPHRASE"
             ],
             env: [{"DELIVEST_BACKUP_PASSPHRASE", secret}],
             stderr_to_stdout: true
           ) do
        {_, 0} -> Storage.put_file(key, encrypted, :offsite)
        _ -> {:error, :backup_encryption_failed}
      end
    after
      File.rm(encrypted)
    end
  end

  defp publish(snapshot, manifest, checksum, size) do
    snapshot
    |> Ecto.Changeset.change(
      status: "ok",
      size: size,
      checksum: checksum,
      release_compatibility:
        Map.take(manifest, ~w(release_version release_manifest_sha256 captured_at)),
      integrity_checked_at: DateTime.utc_now(),
      finished_at: DateTime.utc_now(),
      error: nil
    )
    |> Repo.update()
  end

  defp verify(path, snapshot) do
    script = Path.join(:code.priv_dir(:bastion), "verify-managed-snapshot.py")

    case System.cmd("python3", [script, path, snapshot.instance_id], stderr_to_stdout: true) do
      {json, 0} -> Jason.decode(json)
      _ -> {:error, :invalid_managed_archive}
    end
  end

  def operation_finished(%Operation{action: "backup", status: status} = operation)
      when status in ["ok", "error"] do
    with %Snapshot{status: "pending"} = snapshot <-
           Repo.get_by(Snapshot, node_operation_id: operation.id) do
      fail_pending(
        snapshot.id,
        if(status == "ok",
          do: "нода завершила операцию без архива",
          else: "нода не смогла создать архив"
        )
      )
    end
  end

  def operation_finished(_), do: :ok

  def latest(instance_id) do
    Repo.one(
      from s in Snapshot,
        where:
          s.instance_id == ^instance_id and not is_nil(s.node_operation_id) and s.status == "ok",
        order_by: [desc: s.finished_at],
        limit: 1
    )
  end

  def last_restore_checked(instance_id) do
    Repo.one(
      from s in Snapshot,
        where:
          s.instance_id == ^instance_id and not is_nil(s.node_operation_id) and
            s.status == "ok" and not is_nil(s.restore_checked_at),
        order_by: [desc: s.finished_at, desc: s.id],
        limit: 1
    )
  end

  def current(instance_id) do
    Repo.one(
      from s in Snapshot,
        where: s.instance_id == ^instance_id and not is_nil(s.node_operation_id),
        order_by: [desc: s.inserted_at],
        limit: 1
    )
  end

  def confirm_restore(snapshot_id, actor, evidence)
      when is_binary(actor) and is_binary(evidence) do
    evidence = String.trim(evidence)

    if byte_size(evidence) not in 10..1000 do
      {:error, :restore_evidence_required}
    else
      result =
        Repo.transaction(fn ->
          candidate = Repo.get(Snapshot, snapshot_id) || Repo.rollback(:snapshot_not_found)
          Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [candidate.instance_id])

          snapshot =
            Repo.one(from s in Snapshot, where: s.id == ^snapshot_id, lock: "FOR UPDATE") ||
              Repo.rollback(:snapshot_not_found)

          if is_nil(snapshot.node_operation_id) or snapshot.status != "ok" or
               is_nil(snapshot.integrity_checked_at),
             do: Repo.rollback(:snapshot_not_ready)

          latest_checked = last_restore_checked(snapshot.instance_id)

          if latest_checked && latest_checked.id != snapshot.id &&
               DateTime.compare(latest_checked.finished_at, snapshot.finished_at) != :lt,
             do: Repo.rollback(:newer_restore_verified)

          if snapshot.restore_checked_at do
            snapshot
          else
            snapshot
            |> Ecto.Changeset.change(
              restore_checked_at: DateTime.utc_now(),
              restore_checked_by: actor,
              restore_evidence: evidence
            )
            |> Repo.update!()
          end
        end)

      case result do
        {:ok, snapshot} ->
          failures = prune_verified_predecessors(snapshot)

          snapshot =
            snapshot
            |> Ecto.Changeset.change(
              error: if(failures == 0, do: nil, else: "не удалось очистить прежние копии")
            )
            |> Repo.update!()

          broadcast(snapshot)
          {:ok, snapshot}

        error ->
          error
      end
    end
  end

  def confirm_restore(_, _, _), do: {:error, :restore_evidence_required}

  defp prune_verified_predecessors(snapshot) do
    Repo.all(
      from s in Snapshot,
        where:
          s.instance_id == ^snapshot.instance_id and not is_nil(s.node_operation_id) and
            s.status == "ok" and s.id != ^snapshot.id and s.inserted_at < ^snapshot.inserted_at
    )
    |> Enum.reduce(0, fn old, failures ->
      active_use =
        Repo.exists?(
          from o in Operation,
            where:
              o.instance_id == ^old.instance_id and
                o.status in ~w(pending running waiting_external unknown) and
                fragment(
                  "?->>'backup_id' = ? OR ?->>'snapshot_id' = ?",
                  o.args,
                  ^old.id,
                  o.args,
                  ^old.id
                )
        )

      if not active_use and Storage.delete(old.key, :offsite) == :ok do
        old |> Ecto.Changeset.change(status: "obsolete") |> Repo.update!()
        failures
      else
        failures + 1
      end
    end)
  end

  def fail_stale do
    since = DateTime.add(DateTime.utc_now(), -7200)

    Repo.all(
      from s in Snapshot,
        where:
          not is_nil(s.node_operation_id) and s.status == "pending" and s.inserted_at < ^since
    )
    |> Enum.each(&fail_pending(&1.id, "полная копия не завершилась за два часа"))
  end

  defp fail_pending(id, reason) do
    {changed, _} =
      Repo.update_all(from(s in Snapshot, where: s.id == ^id and s.status == "pending"),
        set: [status: "error", error: reason, finished_at: DateTime.utc_now()]
      )

    if changed == 1 do
      snapshot = Snapshots.get(id)
      broadcast(snapshot)
      Alerts.send_message("💾 #{snapshot.instance_name}: управляемая копия не создана\n#{reason}")
    end

    :ok
  end

  defp broadcast(snapshot),
    do: Phoenix.PubSub.broadcast(Bastion.PubSub, "instances", {:snapshot_updated, snapshot})
end
