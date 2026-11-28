defmodule Bastion.Snapshots do
  import Ecto.Query, warn: false

  alias Bastion.{Alerts, Instances, Repo, Storage}
  alias Bastion.Instances.{Command, Instance}
  alias Bastion.Snapshots.{Snapshot, Verifier}

  @topic "instances"
  @token_max_age 7200
  @stale_after_seconds 3600

  def supported?(%Instance{actions: actions}), do: "full_backup" in actions

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id), do: Repo.get(Snapshot, id)
  end

  def latest(instance_id) do
    Snapshot
    |> where(
      [s],
      s.instance_id == ^instance_id and is_nil(s.node_operation_id) and s.status == "ok"
    )
    |> order_by([s], desc: s.finished_at, desc: s.id)
    |> limit(1)
    |> Repo.one()
  end

  def current(instance_id) do
    Snapshot
    |> where([s], s.instance_id == ^instance_id and is_nil(s.node_operation_id))
    |> order_by([s], desc: s.inserted_at, desc: s.id)
    |> limit(1)
    |> Repo.one()
  end

  def start(%Instance{} = instance, requested_by \\ nil) do
    cond do
      not Storage.configured?() -> {:error, :storage_unavailable}
      not supported?(instance) -> {:error, :unsupported}
      not instance.online -> {:error, :offline}
      Instances.busy?(instance.id) -> {:error, :busy}
      true -> create_and_send(instance, requested_by)
    end
  end

  defp create_and_send(instance, requested_by) do
    id = Ecto.UUID.generate()
    stamp = Calendar.strftime(DateTime.utc_now(), "%Y-%m-%d-%H%M")

    snapshot =
      %Snapshot{
        id: id,
        instance_id: instance.id,
        instance_name: instance.name,
        key: "snapshots/#{instance.id}/#{stamp}-#{id}.tar",
        requested_by: requested_by
      }

    case snapshot
         |> Ecto.Changeset.change()
         |> Ecto.Changeset.unique_constraint(:instance_id,
           name: :snapshots_one_pending_per_instance
         )
         |> Repo.insert() do
      {:ok, snapshot} ->
        args = %{
          "upload_url" => BastionWeb.Endpoint.url() <> "/agent/backups/snapshots/#{id}",
          "token" => sign(:upload, snapshot)
        }

        case Instances.send_command(instance, "full_backup", args, requested_by) do
          {:ok, command} ->
            snapshot
            |> Ecto.Changeset.change(command_id: command.id)
            |> Repo.update()
            |> broadcast()

          {:error, reason} ->
            fail(snapshot, inspect(reason))
        end

      {:error, %Ecto.Changeset{}} ->
        {:error, :busy}
    end
  end

  def authorize_upload(id, token) when is_binary(token) do
    with %Snapshot{status: "pending"} = snapshot <- get(id),
         {:ok, signed_id} when signed_id == snapshot.id <-
           Phoenix.Token.verify(BastionWeb.Endpoint, "snapshot upload", token,
             max_age: @token_max_age
           ) do
      {:ok, snapshot}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize_upload(_id, _token), do: {:error, :unauthorized}

  def store(%Snapshot{} = candidate, path) do
    with :ok <- Verifier.run(path) do
      result =
        Repo.transaction(
          fn ->
            Repo.query!("SELECT pg_advisory_xact_lock(hashtext($1))", [candidate.instance_id])

            snapshot =
              Repo.one(from s in Snapshot, where: s.id == ^candidate.id, lock: "FOR UPDATE")

            if snapshot && snapshot.status == "pending" do
              case Storage.put_file(snapshot.key, path) do
                :ok ->
                  published =
                    snapshot
                    |> Ecto.Changeset.change(
                      status: "ok",
                      size: File.stat!(path).size,
                      error: nil,
                      finished_at: now()
                    )
                    |> Repo.update!()

                  Snapshot
                  |> where(
                    [s],
                    s.instance_id == ^candidate.instance_id and is_nil(s.node_operation_id) and
                      s.status == "ok" and
                      s.id != ^candidate.id
                  )
                  |> Repo.update_all(set: [status: "obsolete"])

                  published

                {:error, reason} ->
                  Repo.rollback({:storage, reason})
              end
            else
              Repo.rollback(:already_processed)
            end
          end,
          timeout: 900_000
        )

      case result do
        {:ok, snapshot} ->
          broadcast({:ok, snapshot})
          prune(snapshot.instance_id)
          {:ok, snapshot}

        {:error, :already_processed} ->
          {:error, :unauthorized}

        {:error, {:storage, reason}} ->
          Storage.delete(candidate.key)
          fail(candidate, "не удалось сохранить слепок: #{reason}")

        {:error, reason} ->
          Storage.delete(candidate.key)
          fail(candidate, "не удалось записать слепок: #{inspect(reason)}")
      end
    else
      {:error, reason} -> fail(candidate, "архив повреждён: #{reason}")
    end
  end

  def fetch(%Snapshot{status: "ok"} = snapshot, path),
    do: Storage.download(snapshot.key, path)

  def filename(%Snapshot{} = snapshot) do
    name =
      snapshot.instance_name
      |> String.replace(~r/[^\p{L}\p{N}]+/u, "-")
      |> String.trim("-")

    extension =
      case snapshot do
        %Snapshot{kind: "postgres"} -> "postgres.dump"
        %Snapshot{node_operation_id: id} when not is_nil(id) -> "full.tar.gz"
        _ -> "full.tar"
      end

    "#{name}-#{Calendar.strftime(snapshot.inserted_at, "%Y-%m-%d-%H%M")}-#{extension}"
  end

  def command_finished(%Command{action: "full_backup", status: status} = command)
      when status in ["ok", "error"] do
    with %Snapshot{status: "pending"} = snapshot <- Repo.get_by(Snapshot, command_id: command.id) do
      fail(
        snapshot,
        if(status == "ok",
          do: "агент завершил работу без архива",
          else: last_lines(command.output)
        )
      )
    end
  end

  def command_finished(_), do: :ok

  def fail_stale do
    since = DateTime.add(now(), -@stale_after_seconds)

    Snapshot
    |> where(
      [s],
      is_nil(s.node_operation_id) and s.status == "pending" and s.inserted_at < ^since
    )
    |> Repo.all()
    |> Enum.each(&fail(&1, "слепок не завершился за час"))
  end

  def run_daily do
    fail_stale()
    Bastion.ManagedSnapshots.fail_stale()

    for instance <- Instances.list_instances(), supported?(instance) do
      Oban.insert(Bastion.Snapshots.Worker.new(%{instance_id: instance.id}))
    end

    for instance <- Instances.list_instances(),
        instance.transport == "node",
        Bastion.Nodes.placement_for(instance.id) do
      Oban.insert(Bastion.ManagedSnapshots.Worker.new(%{instance_id: instance.id}))
    end

    :ok
  end

  defp prune(instance_id) do
    Snapshot
    |> where(
      [s],
      s.instance_id == ^instance_id and is_nil(s.node_operation_id) and s.status == "obsolete"
    )
    |> Repo.all()
    |> Enum.each(fn old ->
      if Storage.delete(old.key) == :ok, do: Repo.delete(old)
    end)
  end

  defp fail(snapshot, reason) do
    {changed, _} =
      Snapshot
      |> where([s], s.id == ^snapshot.id and s.status == "pending")
      |> Repo.update_all(set: [status: "error", error: reason, finished_at: now()])

    if changed == 1 do
      snapshot = Repo.get!(Snapshot, snapshot.id)
      broadcast({:ok, snapshot})
      Alerts.send_message("💾 #{snapshot.instance_name}: полный слепок не сделан\n#{reason}")
    end

    {:error, reason}
  end

  defp last_lines(nil), do: "агент вернул ошибку"

  defp last_lines(output),
    do: output |> String.split("\n", trim: true) |> Enum.take(-5) |> Enum.join("\n")

  defp sign(:upload, snapshot),
    do: Phoenix.Token.sign(BastionWeb.Endpoint, "snapshot upload", snapshot.id)

  defp broadcast({:ok, snapshot} = result) do
    Phoenix.PubSub.broadcast(Bastion.PubSub, @topic, {:snapshot_updated, snapshot})
    result
  end

  defp now, do: DateTime.utc_now()
end
