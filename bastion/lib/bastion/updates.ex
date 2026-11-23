defmodule Bastion.Updates do
  @moduledoc "Updates a site, with a fresh database backup first when the agent can make one."

  alias Bastion.{Backups, Instances, Releases}
  alias Bastion.Instances.Instance

  # Agents that know `rollback` also back up the database as the first step of an update.
  def backup_first?(%Instance{actions: actions}), do: "rollback" in actions

  # Legacy callers cannot safely select a mutable latest tag.
  def update(%Instance{}, _requested_by), do: {:error, :version_required}

  def update(%Instance{} = instance, version, requested_by) do
    with true <-
           "release_manifest_v1" in instance.capabilities or {:error, :agent_upgrade_required},
         {:ok, bundle} <- Releases.resolve(version) do
      current = get_in(instance.status || %{}, ["rollback", "current", "version"])

      if Releases.newer?(version, current),
        do: do_update(instance, bundle.manifest, requested_by),
        else: {:error, :already_current}
    end
  end

  defp do_update(instance, manifest, requested_by) do
    prepared =
      if backup_first?(instance),
        do: Backups.prepare_for_update(instance, requested_by),
        else: :skip

    case prepared do
      {:ok, backup, args} ->
        case Instances.send_command(
               instance,
               "update",
               Map.put(args, "release", manifest),
               requested_by
             ) do
          {:ok, command} ->
            Backups.attach_command(backup, command)
            {:ok, command}

          error ->
            Backups.discard(backup)
            error
        end

      :skip ->
        Instances.send_command(instance, "update", %{"release" => manifest}, requested_by)
    end
  end
end
