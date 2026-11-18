defmodule Bastion.Snapshots.Verifier do
  @moduledoc "Checks the full archive's structure and both manifest digests without loading it into memory."

  alias Bastion.Snapshots.Archive

  def run(path) do
    directory = Path.join(System.tmp_dir!(), "bastion-snapshot-check-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    try do
      with :ok <- Archive.validate(path, :outer),
           :ok <- extract_entry(path, "manifest.json", directory),
           {:ok, manifest} <- read_manifest(Path.join(directory, "manifest.json")),
           :ok <- extract_entry(path, "database.dump", directory),
           :ok <- extract_entry(path, "storage.tar", directory),
           :ok <- match_digest(manifest, "database_dump", Path.join(directory, "database.dump")),
           :ok <- match_digest(manifest, "storage_tar", Path.join(directory, "storage.tar")),
           :ok <- Archive.validate(Path.join(directory, "storage.tar"), :storage),
           :ok <- verify_dump(Path.join(directory, "database.dump")) do
        :ok
      end
    after
      File.rm_rf!(directory)
    end
  end

  defp extract_entry(archive, name, directory) do
    path = Path.join(directory, name)

    case System.cmd("tar", ["-xOf", archive, name], into: File.stream!(path)) do
      {_, 0} -> :ok
      _ -> {:error, "не удалось прочитать #{name} из архива"}
    end
  end

  defp read_manifest(path) do
    with {:ok, %{size: size}} when size <= 100_000 <- File.stat(path),
         {:ok, json} <- File.read(path),
         {:ok, %{"format" => "delivest-full", "version" => 1, "files" => files} = manifest} <-
           Jason.decode(json),
         true <- is_map(files) do
      {:ok, manifest}
    else
      _ -> {:error, "неверный манифест полного слепка"}
    end
  end

  defp match_digest(manifest, key, path) do
    expected = get_in(manifest, ["files", key])

    with %{"size" => size, "sha256" => hash} when is_integer(size) and is_binary(hash) <-
           expected,
         {:ok, %{size: ^size, sha256: ^hash}} <- Archive.digest(path) do
      :ok
    else
      _ -> {:error, "контрольная сумма #{key} не совпадает"}
    end
  end

  defp verify_dump(path) do
    case File.open(path, [:read, :binary], &IO.binread(&1, 5)) do
      {:ok, "PGDMP"} -> run_pg_restore(path)
      _ -> {:error, "в архиве нет дампа PostgreSQL"}
    end
  end

  defp run_pg_restore(path) do
    case System.find_executable(Application.get_env(:bastion, :pg_restore, "pg_restore")) do
      nil ->
        {:error, "pg_restore недоступен для проверки слепка"}

      executable ->
        case System.cmd(executable, ["--list", path], stderr_to_stdout: true) do
          {_, 0} ->
            case System.cmd(executable, ["--file", "/dev/null", path], stderr_to_stdout: true) do
              {_, 0} -> :ok
              _ -> {:error, "дамп PostgreSQL не читается"}
            end

          _ ->
            {:error, "дамп PostgreSQL не читается"}
        end
    end
  end
end
