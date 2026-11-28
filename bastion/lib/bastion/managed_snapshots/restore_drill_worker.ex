defmodule Bastion.ManagedSnapshots.RestoreDrillWorker do
  @moduledoc "Runs an offsite restore on a dedicated verifier without publishing a franchise."
  use Oban.Worker,
    queue: :recovery,
    max_attempts: 1,
    unique: [period: 86_400, keys: [:snapshot_id]]

  alias Bastion.{ManagedSnapshots, Nodes, Repo}
  alias Bastion.Snapshots.Snapshot

  @checks ~w(archive_integrity postgres_boot application_schema media_files)

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(45)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"snapshot_id" => id}}) do
    with config when is_binary(config) <- ssh_config(),
         %Snapshot{status: "ok", kind: "full", node_operation_id: operation_id} = snapshot
         when not is_nil(operation_id) <- Repo.get(Snapshot, id) do
      result = restore(snapshot, config)
      record(snapshot, result)
    else
      _ -> :ok
    end
  end

  def perform(%Oban.Job{args: args}) when map_size(args) == 0 do
    if ssh_config() do
      jobs =
        for {id, _placement} <- Nodes.active_placements(),
            %Snapshot{id: snapshot_id} <- [ManagedSnapshots.latest(id)],
            do: new(%{snapshot_id: snapshot_id})

      Enum.each(jobs, &Oban.insert/1)
    end

    :ok
  end

  defp ssh_config, do: Application.get_env(:bastion, :recovery_drill_ssh_config)

  defp restore(snapshot, config) do
    directory = Path.join(System.tmp_dir!(), "delivest-drill-" <> Ecto.UUID.generate())
    archive = Path.join(directory, "snapshot.tar.gz")

    try do
      with :ok <- File.mkdir(directory),
           :ok <- File.chmod(directory, 0o700),
           :ok <- ManagedSnapshots.fetch(snapshot, archive),
           {:ok, evidence} <- verify(archive, config, snapshot) do
        {:ok, evidence}
      end
    after
      File.rm_rf(directory)
    end
  end

  defp verify(archive, config, snapshot) do
    adapter = Application.get_env(:bastion, :recovery_drill_adapter, __MODULE__)

    with {output, 0} <- adapter.run(archive, config, snapshot),
         {:ok,
          %{
            "status" => "ok",
            "instance_id" => id,
            "archive_sha256" => digest,
            "release_version" => version,
            "checks" => checks
          }} <- Jason.decode(output),
         true <- id == snapshot.instance_id and digest == snapshot.checksum,
         true <- is_binary(version) and byte_size(version) in 1..100,
         true <- checks == @checks do
      {:ok,
       %{
         "release_version" => version,
         "checks" => @checks,
         "sha256" => digest
       }}
    else
      _ -> {:error, :isolated_verifier_failed}
    end
  end

  def run(archive, config, snapshot) do
    System.cmd(
      "sh",
      [
        "-c",
        ~S(archive=$1; shift; exec timeout -k 10s 1800s ssh "$@" < "$archive"),
        "delivest-recovery",
        archive,
        "-F",
        config,
        "-o",
        "BatchMode=yes",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "ConnectTimeout=10",
        "--",
        "delivest-recovery-verifier",
        "verify",
        snapshot.checksum,
        snapshot.instance_id
      ],
      stderr_to_stdout: true
    )
  rescue
    ErlangError -> {"", 1}
  end

  defp record(snapshot, {:ok, evidence}), do: persist(snapshot, "ok", evidence)

  defp record(snapshot, {:error, :isolated_verifier_failed}),
    do: persist(snapshot, "error", %{"reason" => "Не прошла проверка на сервере восстановления"})

  defp record(snapshot, _),
    do: persist(snapshot, "error", %{"reason" => "Не удалось подготовить внешнюю копию"})

  defp persist(snapshot, status, result) do
    case snapshot
         |> Ecto.Changeset.change(
           drill_at: DateTime.utc_now(),
           drill_status: status,
           drill_result: result
         )
         |> Repo.update() do
      {:ok, _} -> :ok
      {:error, _} -> {:error, :restore_drill_result_not_saved}
    end
  end
end
