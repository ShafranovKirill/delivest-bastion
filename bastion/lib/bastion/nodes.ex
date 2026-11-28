defmodule Bastion.Nodes do
  import Ecto.Query

  alias Bastion.Instances.Instance
  alias Bastion.Nodes.{MetricSample, Node, Operation, Placement}
  alias Bastion.Repo

  @actions ~w(status start stop)
  @unresolved ~w(pending running waiting_external unknown)
  @deliverable ~w(pending running unknown)
  @topic "managed_nodes"

  def subscribe, do: Phoenix.PubSub.subscribe(Bastion.PubSub, @topic)

  def subscribe_commands(node_id),
    do: Phoenix.PubSub.subscribe(Bastion.PubSub, "node_commands:#{node_id}")

  def list_nodes, do: Repo.all(from n in Node, order_by: [asc: n.name])

  def get_node(id) do
    case Ecto.UUID.cast(id) do
      {:ok, id} -> Repo.get(Node, id)
      _ -> nil
    end
  end

  def list_placements(node_id),
    do:
      Repo.all(
        from p in Placement,
          where: p.node_id == ^node_id,
          preload: [:instance],
          order_by: [asc: p.inserted_at]
      )

  def placement_for(instance_id),
    do:
      Repo.one(
        from p in Placement,
          where: p.instance_id == ^instance_id and p.state == "active",
          preload: [:node]
      )

  def active_placements do
    Repo.all(from p in Placement, where: p.state == "active", preload: [:node])
    |> Map.new(&{&1.instance_id, &1})
  end

  def list_operations(limit \\ 100),
    do:
      Repo.all(
        from o in Operation,
          preload: [:node, :instance],
          order_by: [desc: o.inserted_at],
          limit: ^limit
      )

  def operations_for(instance_id),
    do:
      Repo.all(
        from o in Operation, where: o.instance_id == ^instance_id, order_by: [desc: o.inserted_at]
      )

  def connected_instance_ids do
    cutoff = DateTime.add(DateTime.utc_now(), -90)

    Repo.all(
      from p in Placement,
        join: n in Node,
        on: n.id == p.node_id,
        where:
          p.state == "active" and n.last_seen_at > ^cutoff and
            is_nil(n.credential_revoked_at) and not is_nil(n.credential_hash),
        select: p.instance_id
    )
    |> MapSet.new()
  end

  def rename_instance(instance_id, name) when is_binary(name) do
    with {:ok, id} <- Ecto.UUID.cast(instance_id),
         %Instance{transport: "node"} = instance <- Repo.get(Instance, id) do
      result =
        instance
        |> Ecto.Changeset.change(name: String.trim(name))
        |> Ecto.Changeset.validate_required([:name])
        |> Ecto.Changeset.validate_length(:name, max: 255)
        |> Repo.update()

      case result do
        {:ok, updated} ->
          broadcast()
          {:ok, updated}

        error ->
          error
      end
    else
      _ -> {:error, :not_managed}
    end
  end

  def pending_operations(node_id) do
    Repo.all(
      from o in Operation,
        where: o.node_id == ^node_id and o.status in ^@deliverable,
        order_by: [asc: o.inserted_at]
    )
    |> Enum.filter(&deliverable?/1)
  end

  def deliverable?(%Operation{instance_id: nil}), do: true

  def deliverable?(%Operation{} = operation) do
    Repo.exists?(
      from p in Placement,
        join: i in Instance,
        on: i.id == p.instance_id,
        where:
          p.id == ^operation.placement_id and p.node_id == ^operation.node_id and
            p.revision == ^operation.placement_revision and p.state == "active" and
            i.transport == "node"
    )
  end

  def create_node(name) when is_binary(name) do
    token = secret()

    result =
      %Node{}
      |> Node.changeset(%{name: name})
      |> Ecto.Changeset.put_change(:registration_token_hash, hash(token))
      |> Repo.insert()

    case result do
      {:ok, node} ->
        broadcast()
        {:ok, node, token}

      error ->
        error
    end
  end

  def reset_registration(%Node{} = node) do
    token = secret()

    case node |> Ecto.Changeset.change(registration_token_hash: hash(token)) |> Repo.update() do
      {:ok, updated} -> {:ok, updated, token}
      error -> error
    end
  end

  def register(token, 1) when is_binary(token) do
    credential = secret()

    result =
      Repo.transaction(fn ->
        node =
          Repo.one(
            from n in Node, where: n.registration_token_hash == ^hash(token), lock: "FOR UPDATE"
          )

        if node do
          node
          |> Ecto.Changeset.change(
            registration_token_hash: nil,
            credential_hash: hash(credential),
            credential_revoked_at: nil,
            credential_revision: node.credential_revision + 1
          )
          |> Repo.update!()
        else
          Repo.rollback(:invalid_token)
        end
      end)

    case result do
      {:ok, node} ->
        broadcast()
        {:ok, node, credential}

      error ->
        error
    end
  end

  def register(_token, _version), do: {:error, :unsupported_protocol}

  def authenticate(node_id, credential) when is_binary(node_id) and is_binary(credential) do
    with {:ok, id} <- Ecto.UUID.cast(node_id),
         %Node{} = node <- Repo.get(Node, id),
         true <- is_binary(node.credential_hash) and is_nil(node.credential_revoked_at),
         true <- Plug.Crypto.secure_compare(node.credential_hash, hash(credential)) do
      {:ok, node}
    else
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate(_, _), do: {:error, :unauthorized}

  def authenticate_credential(credential) when is_binary(credential) do
    digest = hash(credential)

    case Repo.one(
           from n in Node, where: n.credential_hash == ^digest and is_nil(n.credential_revoked_at)
         ) do
      %Node{} = node -> {:ok, node}
      _ -> {:error, :unauthorized}
    end
  end

  def authenticate_credential(_), do: {:error, :unauthorized}

  def credential_active?(node_id, revision) do
    Repo.exists?(
      from n in Node,
        where:
          n.id == ^node_id and n.credential_revision == ^revision and
            is_nil(n.credential_revoked_at) and not is_nil(n.credential_hash)
    )
  end

  def revoke(%Node{} = node) do
    node
    |> Ecto.Changeset.change(credential_hash: nil, credential_revoked_at: DateTime.utc_now())
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        BastionWeb.Endpoint.broadcast("node:#{node.id}", "disconnect", %{})
        broadcast()
        {:ok, updated}

      error ->
        error
    end
  end

  def create_placement(instance_id, node_id, project_name, port) do
    with {:ok, instance_id} <- Ecto.UUID.cast(instance_id),
         {:ok, node_id} <- Ecto.UUID.cast(node_id) do
      Repo.transaction(fn -> insert_placement(instance_id, node_id, project_name, port) end)
      |> case do
        {:ok, placement} ->
          broadcast()
          {:ok, placement}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_target}
    end
  end

  def prepare_instance(node_id, instance_id, name, hosts, project_name, port)
      when is_binary(name) and is_map(hosts) do
    with {:ok, node_id} <- Ecto.UUID.cast(node_id),
         {:ok, instance_id} <- Ecto.UUID.cast(instance_id) do
      Repo.transaction(fn ->
        _node = Repo.get(Node, node_id) || Repo.rollback(:node_not_found)
        if Repo.get(Instance, instance_id), do: Repo.rollback(:already_registered)

        changeset =
          %Instance{id: instance_id, transport: "node"}
          |> Instance.register_changeset(%{"name" => String.trim(name), "hosts" => hosts})
          |> Ecto.Changeset.unique_constraint(:id, name: :instances_pkey)

        case Repo.insert(changeset) do
          {:ok, _instance} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end

        insert_placement(instance_id, node_id, project_name, port)
      end)
      |> case do
        {:ok, placement} ->
          broadcast()
          {:ok, placement}

        error ->
          error
      end
    else
      _ -> {:error, :invalid_target}
    end
  end

  def prepare_instance(_, _, _, _, _, _), do: {:error, :invalid_input}

  defp insert_placement(instance_id, node_id, project_name, port) do
    instance =
      Repo.one(from i in Instance, where: i.id == ^instance_id, lock: "FOR UPDATE") ||
        Repo.rollback(:instance_not_found)

    if instance.transport != "node", do: Repo.rollback(:legacy_conversion_out_of_scope)

    node = Repo.get(Node, node_id) || Repo.rollback(:node_not_found)

    existing =
      Repo.one(from p in Placement, where: p.instance_id == ^instance.id and p.state == "active")

    if existing, do: Repo.rollback(:already_placed)

    revision =
      (Repo.one(
         from p in Placement, where: p.instance_id == ^instance.id, select: max(p.revision)
       ) || 0) + 1

    changeset =
      %Placement{instance_id: instance.id, node_id: node.id}
      |> Placement.changeset(%{
        revision: revision,
        project_name: project_name,
        gateway_port: port,
        state: "active"
      })

    placement =
      case Repo.insert(changeset) do
        {:ok, placement} -> placement
        {:error, changeset} -> Repo.rollback(changeset)
      end

    placement
  end

  def queue(instance_id, action, requested_by, args \\ %{})

  def queue(instance_id, action, requested_by, args) when action in @actions and args == %{} do
    case Ecto.UUID.cast(instance_id) do
      {:ok, id} -> do_queue(id, action, requested_by, args)
      _ -> {:error, :invalid_target}
    end
  end

  def queue(_, _, _, _), do: {:error, :invalid_action_or_args}

  defp do_queue(instance_id, action, requested_by, args) do
    result =
      Repo.transaction(fn ->
        instance =
          Repo.one(from i in Instance, where: i.id == ^instance_id, lock: "FOR UPDATE") ||
            Repo.rollback(:instance_not_found)

        placement =
          Repo.one(
            from p in Placement, where: p.instance_id == ^instance.id and p.state == "active"
          ) || Repo.rollback(:placement_not_found)

        if instance.transport != "node", do: Repo.rollback(:not_managed)

        if Repo.exists?(
             from o in Operation,
               where: o.instance_id == ^instance.id and o.status in ^@unresolved
           ),
           do: Repo.rollback(:busy)

        changeset =
          %Operation{
            node_id: placement.node_id,
            instance_id: instance.id,
            placement_id: placement.id,
            placement_revision: placement.revision
          }
          |> Operation.changeset(%{action: action, args: args, requested_by: requested_by})

        operation =
          case Repo.insert(changeset) do
            {:ok, operation} -> operation
            {:error, changeset} -> Repo.rollback(changeset)
          end

        if action in ~w(start stop) do
          desired = if action == "start", do: "running", else: "stopped"
          instance |> Ecto.Changeset.change(desired_state: desired) |> Repo.update!()
        end

        operation
      end)

    case result do
      {:ok, operation} ->
        Phoenix.PubSub.broadcast(
          Bastion.PubSub,
          "node_commands:#{operation.node_id}",
          {:push_operation, operation}
        )

        broadcast()
        {:ok, operation}

      error ->
        error
    end
  end

  def command_payload(%Operation{} = operation) do
    %{
      protocol_version: 1,
      operation_id: operation.id,
      node_id: operation.node_id,
      instance_id: operation.instance_id,
      placement_revision: operation.placement_revision,
      action: operation.action,
      args: operation.args
    }
  end

  def update_operation(node_id, operation_id, event, payload) do
    result =
      Repo.transaction(fn ->
        operation =
          Repo.one(
            from o in Operation,
              where: o.id == ^operation_id and o.node_id == ^node_id,
              lock: "FOR UPDATE"
          ) || Repo.rollback(:operation_not_found)

        if operation.instance_id && !current_placement?(operation),
          do: Repo.rollback(:stale_placement)

        transition(operation, event, payload)
      end)

    case result do
      {:ok, operation} ->
        broadcast()
        {:ok, operation}

      error ->
        error
    end
  end

  def record_heartbeat(node_id, payload) when is_map(payload) do
    with %Node{} = node <- Repo.get(Node, node_id),
         sampled_raw when is_binary(sampled_raw) <- payload["sampled_at"],
         {:ok, parsed_at, _} <- DateTime.from_iso8601(sampled_raw),
         sample_id when is_binary(sample_id) and byte_size(sample_id) in 1..128 <-
           payload["sample_id"],
         metrics when is_map(metrics) <- payload["metrics"],
         instances when is_list(instances) <- payload["instances"],
         version when is_binary(version) <- payload["version"],
         true <- Enum.all?(instances, &valid_instance_observation?/1) do
      now = DateTime.utc_now()
      sampled_at = %{parsed_at | microsecond: {elem(parsed_at.microsecond, 0), 6}}

      Repo.transaction(fn ->
        current = Repo.one!(from n in Node, where: n.id == ^node.id, lock: "FOR UPDATE")

        observation =
          if is_nil(current.sampled_at) or
               DateTime.compare(sampled_at, current.sampled_at) != :lt,
             do: [sampled_at: sampled_at, metrics: metrics],
             else: []

        current
        |> Ecto.Changeset.change([last_seen_at: now, version: version] ++ observation)
        |> Repo.update!()

        %MetricSample{
          node_id: node.id,
          sample_id: sample_id,
          sampled_at: sampled_at,
          received_at: now,
          metrics: metrics
        }
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:node_id, :sample_id])

        Enum.each(instances, &record_instance_observation(node.id, &1, sampled_at))
      end)
      |> case do
        {:ok, _} ->
          broadcast()
          :ok

        error ->
          error
      end
    else
      _ -> {:error, :invalid_heartbeat}
    end
  end

  def record_heartbeat(_, _), do: {:error, :invalid_heartbeat}

  defp record_instance_observation(
         node_id,
         %{"instance_id" => instance_id, "placement_revision" => revision, "status" => status} =
           data,
         sampled_at
       ) do
    query =
      from p in Placement,
        where:
          p.node_id == ^node_id and p.instance_id == ^instance_id and p.revision == ^revision and
            p.state == "active" and (is_nil(p.observed_at) or p.observed_at <= ^sampled_at)

    Repo.update_all(query,
      set: [observed_state: status, observed_release: data["release"], observed_at: sampled_at]
    )
  end

  defp record_instance_observation(_, _, _), do: :ok

  defp valid_instance_observation?(%{
         "instance_id" => id,
         "placement_revision" => revision,
         "status" => status
       }) do
    match?({:ok, _}, Ecto.UUID.cast(id)) and is_integer(revision) and revision > 0 and
      status in ~w(running stopped degraded unknown)
  end

  defp valid_instance_observation?(_), do: false

  defp current_placement?(operation) do
    deliverable?(operation)
  end

  defp transition(operation, "command_ack", _payload) do
    if operation.status in ~w(pending running unknown) do
      operation
      |> Ecto.Changeset.change(
        status: "running",
        acknowledged_at: DateTime.utc_now(),
        started_at: operation.started_at || DateTime.utc_now()
      )
      |> Repo.update!()
    else
      operation
    end
  end

  defp transition(operation, "command_progress", %{"progress" => progress})
       when is_map(progress) do
    if operation.status in @unresolved do
      status = if progress["waiting_external"] == true, do: "waiting_external", else: "running"

      operation
      |> Ecto.Changeset.change(
        status: status,
        progress: progress,
        started_at: operation.started_at || DateTime.utc_now()
      )
      |> Repo.update!()
    else
      operation
    end
  end

  defp transition(operation, "command_result", %{"status" => status} = payload)
       when status in ~w(ok error unknown) do
    if operation.status in @unresolved do
      finished_at = if status == "unknown", do: nil, else: DateTime.utc_now()
      result = if is_map(payload["result"]), do: payload["result"], else: %{}

      operation
      |> Ecto.Changeset.change(status: status, result: result, finished_at: finished_at)
      |> Repo.update!()
    else
      operation
    end
  end

  defp transition(_operation, _, _), do: Repo.rollback(:invalid_transition)

  def mark_stale_unknown do
    cutoff = DateTime.add(DateTime.utc_now(), -300)

    {count, _} =
      Repo.update_all(
        from(o in Operation, where: o.status in ["pending", "running"] and o.updated_at < ^cutoff),
        set: [status: "unknown"]
      )

    if count > 0, do: broadcast()
    count
  end

  def prune_metrics(now \\ DateTime.utc_now()) do
    cutoff = DateTime.add(now, -Bastion.Metrics.keep_days() * 86_400)
    {count, _} = Repo.delete_all(from sample in MetricSample, where: sample.sampled_at < ^cutoff)
    count
  end

  defp secret, do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  defp hash(value), do: :crypto.hash(:sha256, value)
  defp broadcast, do: Phoenix.PubSub.broadcast(Bastion.PubSub, @topic, :nodes_updated)
end
