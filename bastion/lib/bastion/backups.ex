defmodule Bastion.Backups do
  import Ecto.Query, warn: false

  alias Bastion.{Alerts, Instances, Repo, Storage}
  alias Bastion.Backups.{Backup, CheckWorker, Verifier}
  alias Bastion.Instances.{Command, Instance}

  @topic "instances"
  @token_max_age 3600
  @stale_after_seconds 3600

  def keep, do: Application.get_env(:bastion, :backups_keep, 7)

  def supported?(%Instance{actions: actions}), do: "backup" in actions and "restore" in actions

  def get(id) do
    with {:ok, id} <- Ecto.UUID.cast(id), do: Repo.get(Backup, id)
  end

  def list(instance_id) do
    Backup
    |> where([b], b.instance_id == ^instance_id)
    |> order_by([b], desc: b.inserted_at, desc: b.id)
    |> limit(20)
    |> Repo.all()
  end

  def start(%Instance{} = instance, requested_by \\ nil) do
    cond do
      not Storage.configured?() ->
        {:error, "хранилище бэкапов не настроено"}

      not supported?(instance) ->
        instance
        |> insert(requested_by)
        |> fail("агент не умеет делать бэкапы, обновите экземпляр")

      true ->
        backup = insert(instance, requested_by)

        args = %{
          "backup_id" => backup.id,
          "upload_url" => url("/agent/backups/#{backup.id}"),
          "token" => sign(:upload, backup)
        }

        case Instances.send_command(instance, "backup", args, requested_by) do
          {:ok, command} ->
            backup
            |> Ecto.Changeset.change(command_id: command.id)
            |> Repo.update()
            |> broadcast()

          {:error, :offline} ->
            fail(backup, "агент не на связи")

          {:error, reason} ->
            fail(backup, inspect(reason))
        end
    end
  end

  # A backup that the agent uploads as the first step of an update.
  def prepare_for_update(%Instance{} = instance, requested_by) do
    if Storage.configured?() and supported?(instance) do
      backup =
        insert(
          instance,
          Enum.join(Enum.reject([requested_by, "перед обновлением"], &is_nil/1), " · ")
        )

      {:ok, backup,
       %{
         "backup_id" => backup.id,
         "upload_url" => url("/agent/backups/#{backup.id}"),
         "token" => sign(:upload, backup)
       }}
    else
      :skip
    end
  end

  def attach_command(%Backup{} = backup, %Command{} = command),
    do: backup |> Ecto.Changeset.change(command_id: command.id) |> Repo.update() |> broadcast()

  def discard(%Backup{} = backup) do
    with {:ok, backup} <- Repo.delete(backup), do: broadcast({:ok, backup})
  end

  def import_file(%Instance{} = instance, path, requested_by \\ nil) do
    cond do
      not Storage.configured?() -> {:error, "хранилище бэкапов не настроено"}
      not pg_dump?(path) -> {:error, "это не дамп базы: нужен файл pg_dump -Fc (.dump)"}
      true -> instance |> insert(requested_by) |> store(path)
    end
  end

  defp pg_dump?(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 5)) do
      {:ok, "PGDMP"} -> true
      _ -> false
    end
  end

  def run_daily do
    fail_stale()

    if Storage.configured?(),
      do: Enum.map(Instances.list_instances(), &start(&1, "расписание")),
      else: Alerts.send_message("💾 Бэкапы не сделаны: хранилище бастиона не настроено")
  end

  def authorize(kind, id, token) when kind in [:upload, :download] and is_binary(token) do
    status = if kind == :upload, do: "pending", else: "ok"

    with %Backup{status: ^status} = backup <- get(id),
         {:ok, backup_id} when backup_id == backup.id <-
           Phoenix.Token.verify(BastionWeb.Endpoint, salt(kind), token, max_age: @token_max_age) do
      {:ok, backup}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authorize(_kind, _id, _token), do: {:error, :unauthorized}

  def store(%Backup{} = backup, path) do
    size = File.stat!(path).size

    case Storage.put_file(backup.key, path) do
      :ok ->
        {:ok, backup} =
          backup
          |> Ecto.Changeset.change(status: "ok", size: size, error: nil, finished_at: now())
          |> Repo.update()
          |> broadcast()

        prune(backup.instance_id)
        Oban.insert(CheckWorker.new(%{backup_id: backup.id}))
        {:ok, backup}

      {:error, reason} ->
        fail(backup, "не удалось сохранить в хранилище: #{reason}")
    end
  end

  def fetch(%Backup{status: "ok"} = backup, path), do: Storage.download(backup.key, path)

  @doc "Reads the stored dump with pg_restore and copies it to the offsite storage."
  def check(id) do
    case get(id) do
      %Backup{status: "ok"} = backup ->
        path = Path.join(System.tmp_dir!(), "bastion-check-#{backup.id}.dump")

        try do
          with :ok <- Storage.download(backup.key, path) do
            backup |> verify(path) |> copy_offsite(path)
            :ok
          end
        after
          File.rm(path)
        end

      _ ->
        :ok
    end
  end

  defp verify(backup, path) do
    {status, error} =
      case Verifier.run(path) do
        :ok -> {"ok", nil}
        :skipped -> {"skipped", nil}
        {:error, reason} -> {"error", reason}
      end

    {:ok, backup} =
      backup
      |> Ecto.Changeset.change(verify_status: status, verify_error: error, verified_at: now())
      |> Repo.update()
      |> broadcast()

    if error do
      Alerts.send_message(
        "💾 #{backup.instance_name}: бэкап от #{Calendar.strftime(backup.inserted_at, "%d.%m %H:%M")} не читается, " <>
          "восстановить из него не получится\n#{error}"
      )
    end

    backup
  end

  defp copy_offsite(backup, path) do
    if Storage.configured?(:offsite) do
      changes =
        case Storage.put_file(backup.key, path, :offsite) do
          :ok ->
            [offsite_at: now(), offsite_error: nil]

          {:error, reason} ->
            Alerts.send_message(
              "💾 #{backup.instance_name}: копия бэкапа не ушла во внешнее хранилище\n#{reason}"
            )

            [offsite_error: reason]
        end

      backup |> Ecto.Changeset.change(changes) |> Repo.update() |> broadcast()
    end
  end

  def command_finished(%Command{action: action, status: status} = command)
      when action in ["backup", "update"] and status in ["ok", "error"] do
    with %Backup{status: "pending"} = backup <- Repo.get_by(Backup, command_id: command.id) do
      reason =
        if status == "ok",
          do: "агент закончил, но файл не дошёл до бастиона",
          else: last_lines(command.output)

      fail(backup, reason)
    end
  end

  def command_finished(_command), do: :ok

  def restore(%Instance{} = target, %Backup{status: "ok"} = backup, requested_by \\ nil) do
    if supported?(target) do
      Instances.send_command(
        target,
        "restore",
        %{
          "backup_id" => backup.id,
          "backup" =>
            "#{backup.instance_name} #{Calendar.strftime(backup.inserted_at, "%d.%m.%Y %H:%M")}",
          "download_url" => url("/agent/backups/#{backup.id}/file"),
          "token" => sign(:download, backup)
        },
        requested_by
      )
    else
      {:error, :unsupported}
    end
  end

  def filename(%Backup{} = backup) do
    name = backup.instance_name |> String.replace(~r/[^\p{L}\p{N}]+/u, "-") |> String.trim("-")
    "#{name}-#{Calendar.strftime(backup.inserted_at, "%Y-%m-%d-%H%M")}.dump"
  end

  def fail_stale do
    since = DateTime.add(now(), -@stale_after_seconds)

    Backup
    |> where([b], b.status == "pending" and b.inserted_at < ^since)
    |> Repo.all()
    |> Enum.each(&fail(&1, "бэкап не завершился за час"))
  end

  def prune(nil), do: :ok

  def prune(instance_id) do
    old =
      Backup
      |> where([b], b.instance_id == ^instance_id and b.status == "ok")
      |> order_by([b], desc: b.inserted_at, desc: b.id)
      |> offset(^keep())
      |> Repo.all()

    for backup <- old, Storage.delete(backup.key) == :ok do
      if backup.offsite_at, do: Storage.delete(backup.key, :offsite)
      Repo.delete(backup)
    end

    failed_before = DateTime.add(now(), -keep() * 86_400)

    Backup
    |> where([b], b.instance_id == ^instance_id and b.status == "error")
    |> where([b], b.inserted_at < ^failed_before)
    |> Repo.delete_all()

    :ok
  end

  defp insert(instance, requested_by) do
    id = Ecto.UUID.generate()
    stamp = Calendar.strftime(now(), "%Y%m%d-%H%M%S")

    {:ok, backup} =
      %Backup{
        id: id,
        instance_id: instance.id,
        instance_name: instance.name,
        key: "#{instance.id}/#{stamp}-#{id}.dump",
        requested_by: requested_by
      }
      |> Repo.insert()
      |> broadcast()

    backup
  end

  defp fail(backup, reason) do
    {:ok, backup} =
      backup
      |> Ecto.Changeset.change(status: "error", error: reason, finished_at: now())
      |> Repo.update()
      |> broadcast()

    Alerts.send_message("💾 #{backup.instance_name}: бэкап не сделан\n#{reason}")
    {:error, reason}
  end

  defp last_lines(nil), do: "агент вернул ошибку"

  defp last_lines(output),
    do: output |> String.split("\n", trim: true) |> Enum.take(-5) |> Enum.join("\n")

  defp sign(kind, backup), do: Phoenix.Token.sign(BastionWeb.Endpoint, salt(kind), backup.id)

  defp salt(:upload), do: "backup upload"
  defp salt(:download), do: "backup download"

  defp url(path), do: BastionWeb.Endpoint.url() <> path

  defp broadcast({:ok, backup} = result) do
    Phoenix.PubSub.broadcast(Bastion.PubSub, @topic, {:backup_updated, backup})
    result
  end

  defp broadcast(error), do: error

  defp now, do: DateTime.utc_now(:second)
end
