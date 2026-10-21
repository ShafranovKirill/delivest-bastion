defmodule Bastion.Instances do
  import Ecto.Query, warn: false

  alias Bastion.Instances.{Command, Instance}
  alias Bastion.Repo
  alias BastionWeb.Presence

  @topic "instances"
  @actions ~w(status update start stop restart logs)

  def actions, do: @actions

  def subscribe, do: Phoenix.PubSub.subscribe(Bastion.PubSub, @topic)

  def subscribe_commands(instance_id),
    do: Phoenix.PubSub.subscribe(Bastion.PubSub, commands_topic(instance_id))

  def list_instances do
    online = Presence.online_ids()

    Instance
    |> order_by([i], asc: i.name)
    |> Repo.all()
    |> Enum.map(&put_online(&1, online))
  end

  def get_instance(id) do
    with {:ok, id} <- Ecto.UUID.cast(id),
         %Instance{} = instance <- Repo.get(Instance, id) do
      put_online(instance, Presence.online_ids())
    else
      _ -> nil
    end
  end

  def register(id, info) do
    attrs = %{
      name: info["name"] || "#{id}",
      hosts: if(is_map(info["hosts"]), do: info["hosts"], else: %{}),
      agent_version: info["agent_version"],
      actions: Enum.filter(List.wrap(info["actions"]), &is_binary/1)
    }

    (Repo.get(Instance, id) || %Instance{id: id})
    |> Instance.register_changeset(attrs)
    |> Ecto.Changeset.put_change(:last_seen_at, now())
    |> Repo.insert_or_update()
    |> broadcast()
  end

  def record_heartbeat(id, status) when is_map(status) do
    case Repo.get(Instance, id) do
      nil ->
        {:error, :not_found}

      instance ->
        instance
        |> Ecto.Changeset.change(status: status, last_seen_at: now())
        |> Repo.update()
        |> broadcast()
    end
  end

  def update_checks(%Instance{} = instance, external, health) do
    instance
    |> Ecto.Changeset.change(external: external, health: to_string(health), checked_at: now())
    |> Repo.update()
    |> broadcast()
  end

  def delete_instance(%Instance{} = instance) do
    with {:ok, instance} <- Repo.delete(instance) do
      BastionWeb.Endpoint.broadcast("agent:#{instance.id}", "disconnect", %{})
      broadcast({:ok, instance}, :instance_deleted)
    end
  end

  def send_command(%Instance{} = instance, action, args \\ %{}, requested_by \\ nil) do
    cond do
      action not in @actions ->
        {:error, :unknown_action}

      not MapSet.member?(Presence.online_ids(), instance.id) ->
        {:error, :offline}

      true ->
        {:ok, command} =
          Repo.insert(%Command{
            instance_id: instance.id,
            action: action,
            args: args,
            status: "sent",
            requested_by: requested_by
          })

        Phoenix.PubSub.broadcast(
          Bastion.PubSub,
          commands_topic(instance.id),
          {:push_command, command}
        )

        broadcast({:ok, command}, :command_updated)
    end
  end

  def command_started(instance_id, command_id) do
    update_command(instance_id, command_id, status: "running", started_at: now())
  end

  def command_finished(instance_id, command_id, ok?, output) do
    update_command(instance_id, command_id,
      status: if(ok?, do: "ok", else: "error"),
      output: format_output(output),
      finished_at: now()
    )
  end

  def list_commands(instance_id, limit \\ 20) do
    Command
    |> where([c], c.instance_id == ^instance_id)
    |> order_by([c], desc: c.inserted_at, desc: c.id)
    |> limit(^limit)
    |> Repo.all()
  end

  defp update_command(instance_id, command_id, changes) do
    with {:ok, command_id} <- Ecto.UUID.cast(command_id),
         %Command{} = command <- Repo.get_by(Command, id: command_id, instance_id: instance_id) do
      command |> Ecto.Changeset.change(changes) |> Repo.update() |> broadcast(:command_updated)
    else
      _ -> {:error, :not_found}
    end
  end

  defp format_output(output) when is_binary(output), do: output
  defp format_output(nil), do: nil
  defp format_output(output), do: Jason.encode!(output, pretty: true)

  defp put_online(instance, online), do: %{instance | online: MapSet.member?(online, instance.id)}

  defp broadcast(result, event \\ :instance_updated)

  defp broadcast({:ok, record} = result, event) do
    Phoenix.PubSub.broadcast(Bastion.PubSub, @topic, {event, record})
    result
  end

  defp broadcast(error, _event), do: error

  defp commands_topic(instance_id), do: "agent_commands:#{instance_id}"

  defp now, do: DateTime.utc_now(:second)
end
