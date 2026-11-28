defmodule Bastion.ManagedUpdates do
  @moduledoc "Queue a pinned release update for a managed installation."

  import Ecto.Query

  alias Bastion.{Nodes, Releases, Repo}
  alias Bastion.Instances.Instance
  alias Bastion.Nodes.{Operation, Placement}
  alias Bastion.Releases.Managed

  @version ~r/\A\d+\.\d+\.\d+\z/
  @sha ~r/\A[0-9a-f]{64}\z/

  def start(instance_id, requested_by, request_key \\ nil, release \\ nil) do
    with {:ok, release} <- resolve(release),
         :ok <- validate_key(request_key),
         {:ok, id} <- Ecto.UUID.cast(instance_id) do
      result =
        Repo.transaction(fn ->
          instance = Repo.one(from i in Instance, where: i.id == ^id, lock: "FOR UPDATE")
          if is_nil(instance) or instance.transport != "node", do: Repo.rollback(:not_managed)

          existing =
            if request_key,
              do: Repo.one(from o in Operation, where: o.request_key == ^request_key),
              else: nil

          if existing do
            if existing.instance_id == id and existing.args == args(release),
              do: {existing, false},
              else: Repo.rollback(:idempotency_conflict)
          else
            operation = queue_pinned!(id, requested_by, release)

            operation =
              if request_key do
                operation
                |> Ecto.Changeset.change(request_key: request_key)
                |> Ecto.Changeset.unique_constraint(:request_key)
                |> Repo.update()
                |> case do
                  {:ok, updated} -> updated
                  {:error, _} -> Repo.rollback(:idempotency_conflict)
                end
              else
                operation
              end

            {operation, true}
          end
        end)

      case result do
        {:ok, {operation, true}} ->
          Nodes.dispatch_operation(operation)
          {:ok, operation}

        {:ok, {operation, false}} ->
          {:ok, operation}

        error ->
          error
      end
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :invalid_update_request}
    end
  end

  def resolve(nil), do: Managed.latest()

  def resolve(%{version: version, url: url, sha256: sha} = release)
      when is_binary(version) and is_binary(url) and is_binary(sha) do
    expected =
      "https://github.com/ShafranovKirill/delivest/releases/download/v#{version}/delivest-deploy-#{version}.tar.gz"

    if Regex.match?(@version, version) and Regex.match?(@sha, sha) and url == expected and
         map_size(release) == 3,
       do: {:ok, release},
       else: {:error, :invalid_release}
  end

  def resolve(_), do: {:error, :invalid_release}

  def args(release),
    do: %{
      "release_url" => release.url,
      "release_sha256" => release.sha256,
      "release_version" => release.version
    }

  @doc "Call only inside a transaction. The caller dispatches after commit."
  def queue_pinned!(instance_id, requested_by, release) do
    placement =
      Repo.one(
        from p in Placement,
          where: p.instance_id == ^instance_id and p.state == "active",
          lock: "FOR UPDATE"
      ) || Repo.rollback(:placement_not_found)

    if placement.observed_state != "running" or is_nil(placement.observed_release),
      do: Repo.rollback(:installation_not_ready)

    if placement.observed_release == release.version,
      do: Repo.rollback(:already_installed)

    unless Releases.newer?(release.version, placement.observed_release),
      do: Repo.rollback(:not_newer)

    case Nodes.queue_deferred(instance_id, "instance_update", requested_by, args(release)) do
      {:ok, operation} -> operation
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_key(nil), do: :ok

  defp validate_key(key) when is_binary(key) and byte_size(key) in 1..255,
    do: :ok

  defp validate_key(_), do: {:error, :invalid_request_key}
end
