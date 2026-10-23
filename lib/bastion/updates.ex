defmodule Bastion.Updates do
  @moduledoc "Updates a site, with a fresh database backup first when the agent can make one."

  alias Bastion.{Backups, Instances}
  alias Bastion.Instances.Instance

  # Agents that know `rollback` also back up the database as the first step of an update.
  def backup_first?(%Instance{actions: actions}), do: "rollback" in actions

  def update(%Instance{} = instance, requested_by \\ nil) do
    prepared =
      if backup_first?(instance),
        do: Backups.prepare_for_update(instance, requested_by),
        else: :skip

    case prepared do
      {:ok, backup, args} ->
        case Instances.send_command(instance, "update", args, requested_by) do
          {:ok, command} ->
            Backups.attach_command(backup, command)
            {:ok, command}

          error ->
            Backups.discard(backup)
            error
        end

      :skip ->
        Instances.send_command(instance, "update", %{}, requested_by)
    end
  end
end
