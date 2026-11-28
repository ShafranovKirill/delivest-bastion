defmodule Bastion.Nodes do
  import Ecto.Query

  alias Bastion.Instances.Instance
  alias Bastion.Nodes.{MetricSample, Node, Operation, Placement, SshInstaller}
  alias Bastion.Repo

  @actions ~w(status start stop diagnostics backup backup_database instance_delete domain_prepare domain_release instance_create instance_cleanup domain_activate domain_rollback)
  @unresolved ~w(pending running waiting_external unknown)
  @deliverable ~w(pending running unknown)
  @topic "managed_nodes"

  def subscribe, do: Phoenix.PubSub.subscribe(Bastion.PubSub, @topic)

  def subscribe_commands(node_id),
    do: Phoenix.PubSub.subscribe(Bastion.PubSub, "node_commands:#{node_id}")

  def list_nodes, do: Repo.all(from n in Node, order_by: [asc: n.name])

  def ready?(%Node{} = node) do
    is_nil(node.credential_revoked_at) and not is_nil(node.credential_hash) and
      not is_nil(node.last_seen_at) and
      DateTime.diff(DateTime.utc_now(), node.last_seen_at) < 90 and
      node.infrastructure["ready"] == true
  end

  def update_public_addresses(%Node{} = node, attrs) do
    addresses = [attrs["public_ipv4"], attrs["public_ipv6"]] |> Enum.reject(&(&1 in [nil, ""]))

    if addresses != [] and Enum.all?(addresses, &public_ip?/1) do
      node |> Node.changeset(attrs) |> Repo.update()
    else
      {:error, :invalid_public_address}
    end
  end

  defp public_ip?(value) do
    case :inet.parse_address(String.to_charlist(value)) do
      {:ok, {a, b, _, _}}
      when a in [0, 10, 127] or a >= 224 or (a == 169 and b == 254) or (a == 172 and b in 16..31) or
             (a == 192 and b == 168) ->
        false

      {:ok, {a, _, _, _}} when a in 1..223 ->
        true

      {:ok, {a, _, _, _, _, _, _, _}} when a >= 0x2000 and a < 0x4000 ->
        true

      _ ->
        false
    end
  end

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
    Repo.all(from p in Placement, where: p.state == "active", preload: [:node, :instance])
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
        where:
          o.node_id == ^node_id and o.status in ^@deliverable and o.action != "provision_node",
        order_by: [asc: o.inserted_at]
    )
    |> Enum.filter(&deliverable?/1)
  end

  def deliverable?(%Operation{instance_id: nil}), do: false

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

  def start_install(name, ssh_attrs) do
    with {:ok, ssh} <- SshInstaller.validate(ssh_attrs) do
      case Repo.get_by(Node, ssh_host: ssh.host, ssh_port: ssh.port) do
        %Node{} = existing ->
          retry_install(existing, ssh_attrs)

        nil ->
          token = secret()

          changeset =
            %Node{}
            |> Node.changeset(%{
              name: name,
              ssh_host: ssh.host,
              ssh_port: ssh.port,
              ssh_login: ssh.login,
              ssh_fingerprint: ssh.fingerprint
            })
            |> Ecto.Changeset.put_change(:registration_token_hash, hash(token))

          with {:ok, node} <- Repo.insert(changeset),
               {:ok, {operation, token}} <- new_install_attempt(node, ssh, token),
               {:ok, _pid} <-
                 Task.Supervisor.start_child(Bastion.TaskSupervisor, fn ->
                   run_install(node, operation, token, ssh_attrs)
                 end) do
            broadcast()
            {:ok, node, operation}
          end
      end
    end
  end

  def retry_install(%Node{} = node, ssh_attrs) do
    with {:ok, ssh} <- SshInstaller.validate(ssh_attrs),
         true <-
           node.ssh_host == ssh.host and node.ssh_port == ssh.port and
             node.ssh_login == ssh.login and node.ssh_fingerprint == ssh.fingerprint,
         {:ok, {operation, token}} <- new_install_attempt(node, ssh, nil),
         {:ok, _pid} <-
           Task.Supervisor.start_child(Bastion.TaskSupervisor, fn ->
             run_install(node, operation, token, ssh_attrs)
           end) do
      {:ok, get_node(node.id), operation}
    else
      false -> {:error, :ssh_identity_changed}
      error -> error
    end
  end

  defp new_install_attempt(node, ssh, supplied_token) do
    Repo.transaction(fn ->
      locked = Repo.one!(from n in Node, where: n.id == ^node.id, lock: "FOR UPDATE")

      active =
        Repo.one(
          from o in Operation,
            where:
              o.node_id == ^node.id and o.action == "provision_node" and
                o.status in ["pending", "running", "waiting_external"],
            limit: 1,
            lock: "FOR UPDATE"
        )

      if active, do: Repo.rollback(:install_in_progress)
      token = supplied_token || secret()

      operation =
        %Operation{node_id: node.id}
        |> Operation.changeset(%{
          action: "provision_node",
          status: "running",
          args: %{},
          requested_by: "admin"
        })
        |> Repo.insert!()

      locked
      |> Ecto.Changeset.change(
        ssh_host: ssh.host,
        ssh_port: ssh.port,
        ssh_login: ssh.login,
        ssh_fingerprint: ssh.fingerprint,
        registration_token_hash: hash(token),
        install_status: "checking_ssh",
        install_error: nil,
        install_progress: %{"stage" => "checking_ssh", "operation_id" => operation.id}
      )
      |> Repo.update!()

      {operation, token}
    end)
  end

  defp run_install(node, operation, token, attrs) do
    result =
      try do
        SshInstaller.install(node, token, attrs)
      rescue
        _ -> {:error, :installer_crashed}
      catch
        _, _ -> {:error, :installer_crashed}
      end

    current = Repo.get!(Node, node.id)

    if current.install_progress["operation_id"] != operation.id,
      do: raise("stale install attempt")

    ready = current.infrastructure["ready"] == true and not is_nil(current.credential_hash)

    status =
      cond do
        result != :ok -> "error"
        ready -> "ready"
        true -> "waiting_registration"
      end

    error = if result == :ok, do: nil, else: inspect(result)

    Repo.get!(Node, node.id)
    |> Ecto.Changeset.change(
      install_status: status,
      install_error: error,
      install_progress: %{"stage" => status, "operation_id" => operation.id}
    )
    |> Repo.update!()

    Repo.get!(Operation, operation.id)
    |> Ecto.Changeset.change(
      status: if(result != :ok, do: "error", else: if(ready, do: "ok", else: "waiting_external")),
      progress: %{"stage" => status},
      result:
        if(result != :ok,
          do: %{"reason" => error},
          else: if(ready, do: %{"ready" => true}, else: %{})
        ),
      finished_at: if(result == :ok and not ready, do: nil, else: DateTime.utc_now())
    )
    |> Repo.update!()

    broadcast()
  end

  def recover_interrupted_installs do
    Repo.all(from o in Operation, where: o.action == "provision_node" and o.status == "running")
    |> Enum.each(fn operation ->
      Repo.transaction(fn ->
        operation
        |> Ecto.Changeset.change(
          status: "unknown",
          result: %{"reason" => "Bastion перезапущен во время SSH-установки"}
        )
        |> Repo.update!()

        node = Repo.get!(Node, operation.node_id)

        if node.install_progress["operation_id"] == operation.id do
          node
          |> Ecto.Changeset.change(
            install_status: "interrupted",
            install_error: "Результат установки неизвестен; повторите с тем же сервером"
          )
          |> Repo.update!()
        end
      end)
    end)

    broadcast()
  end

  def install_stage(node_id, stage)
      when stage in ~w(preflight download packages release systemd registration ready) do
    if node = Repo.get(Node, node_id) do
      node
      |> Ecto.Changeset.change(
        install_status: stage,
        install_progress: Map.put(node.install_progress, "stage", stage)
      )
      |> Repo.update!()

      broadcast()
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

  def queue(instance_id, action, requested_by, args) when action in @actions do
    if valid_args?(action, args) do
      case Ecto.UUID.cast(instance_id) do
        {:ok, id} -> do_queue(id, action, requested_by, args, true)
        _ -> {:error, :invalid_target}
      end
    else
      {:error, :invalid_action_or_args}
    end
  end

  def queue(_, _, _, _), do: {:error, :invalid_action_or_args}

  def queue_deferred(instance_id, action, requested_by, args)
      when action in ~w(backup backup_database domain_prepare domain_release instance_create instance_cleanup domain_activate domain_rollback) do
    if valid_args?(action, args) do
      case Ecto.UUID.cast(instance_id) do
        {:ok, id} -> do_queue(id, action, requested_by, args, false)
        _ -> {:error, :invalid_target}
      end
    else
      {:error, :invalid_action_or_args}
    end
  end

  def dispatch_operation(%Operation{} = operation) do
    Phoenix.PubSub.broadcast(
      Bastion.PubSub,
      "node_commands:#{operation.node_id}",
      {:push_operation, operation}
    )

    broadcast()
    :ok
  end

  defp valid_args?(action, args) when action in ~w(status start stop diagnostics), do: args == %{}

  defp valid_args?(action, %{"backup_id" => id} = args) when action in ~w(backup backup_database),
    do: map_size(args) == 1 and match?({:ok, _}, Ecto.UUID.cast(id))

  defp valid_args?("instance_delete", %{"confirm_instance_id" => id} = args),
    do: map_size(args) == 1 and match?({:ok, _}, Ecto.UUID.cast(id))

  defp valid_args?("instance_create", args) when is_map(args) do
    required =
      ~w(release_url release_sha256 release_version gateway_port site_hostname admin_hostname api_hostname media_hostname site_binding_id admin_binding_id api_binding_id media_binding_id expected_addresses)

    Map.keys(args) |> Enum.sort() == Enum.sort(required) and
      is_binary(args["release_url"]) and
      String.starts_with?(
        args["release_url"],
        "https://github.com/ShafranovKirill/delivest/releases/download/"
      ) and
      is_binary(args["release_sha256"]) and
      Regex.match?(~r/\A[0-9a-f]{64}\z/, args["release_sha256"]) and
      is_binary(args["release_version"]) and
      is_integer(args["gateway_port"]) and args["gateway_port"] in 1024..65_535 and
      Enum.all?(~w(site_hostname admin_hostname api_hostname media_hostname), fn key ->
        host = args[key]
        is_binary(host) and Bastion.Domains.Domain.normalize(host) == host
      end) and
      Enum.all?(~w(site_binding_id admin_binding_id api_binding_id media_binding_id), fn key ->
        match?({:ok, _}, Ecto.UUID.cast(args[key]))
      end) and
      is_list(args["expected_addresses"]) and args["expected_addresses"] != [] and
      Enum.all?(args["expected_addresses"], &is_binary/1)
  end

  defp valid_args?("instance_cleanup", %{"confirm_instance_id" => id, "remove_data" => false})
       when is_binary(id),
       do: match?({:ok, _}, Ecto.UUID.cast(id))

  defp valid_args?(action, args)
       when action in ~w(domain_activate domain_rollback) and is_map(args) do
    Map.keys(args) |> Enum.sort() ==
      Enum.sort(
        ~w(hostname binding_id purpose previous_hostname previous_binding_id verification_id)
      ) and
      args["purpose"] == "site" and
      Enum.all?(~w(hostname previous_hostname), fn key ->
        is_binary(args[key]) and Bastion.Domains.Domain.normalize(args[key]) == args[key]
      end) and
      Enum.all?(~w(binding_id previous_binding_id verification_id), fn key ->
        match?({:ok, _}, Ecto.UUID.cast(args[key]))
      end)
  end

  defp valid_args?(
         action,
         %{
           "hostname" => host,
           "binding_id" => binding_id,
           "purpose" => purpose,
           "expected_addresses" => addresses
         } = args
       )
       when action in ~w(domain_prepare domain_release) do
    Map.keys(args) |> Enum.sort() == ~w(binding_id expected_addresses hostname purpose) and
      Bastion.Domains.Domain.normalize(host) == host and
      match?({:ok, _}, Ecto.UUID.cast(binding_id)) and purpose in ~w(site admin api media) and
      is_list(addresses) and addresses != [] and Enum.all?(addresses, &is_binary/1)
  end

  defp valid_args?(_, _), do: false

  defp do_queue(instance_id, action, requested_by, args, dispatch?) do
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

        if action in ~w(domain_prepare domain_release domain_activate domain_rollback) do
          binding =
            Repo.get(Bastion.Domains.Binding, args["binding_id"]) ||
              Repo.rollback(:binding_not_found)

          domain =
            Repo.get(Bastion.Domains.Domain, binding.domain_id) ||
              Repo.rollback(:domain_not_found)

          if binding.instance_id != instance.id or domain.hostname != args["hostname"] or
               binding.purpose != args["purpose"],
             do: Repo.rollback(:binding_target_mismatch)
        end

        if action == "instance_create" do
          if placement.gateway_port != args["gateway_port"] or
               instance.desired_release != args["release_version"],
             do: Repo.rollback(:release_or_port_mismatch)
        end

        if action == "instance_cleanup" and args["confirm_instance_id"] != instance.id,
          do: Repo.rollback(:instance_mismatch)

        if action == "instance_delete" do
          if args["confirm_instance_id"] != instance.id,
            do: Repo.rollback(:instance_mismatch)

          if instance.desired_state != "stopped" or placement.observed_state != "stopped" or
               is_nil(placement.observed_at) or
               DateTime.diff(DateTime.utc_now(), placement.observed_at) > 120 or
               not ready?(Repo.get!(Node, placement.node_id)),
             do: Repo.rollback(:not_confirmed_stopped)

          if Repo.exists?(
               from b in Bastion.Domains.Binding,
                 where: b.instance_id == ^instance.id and b.state != "released"
             ),
             do: Repo.rollback(:active_domain_bindings)
        end

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
        if dispatch?, do: dispatch_operation(operation)
        {:ok, operation}

      error ->
        error
    end
  end

  def command_payload(%Operation{} = operation) do
    args =
      if operation.action in ~w(backup backup_database) do
        Bastion.ManagedSnapshots.delivery_args(operation)
      else
        operation.args
      end

    %{
      protocol_version: 1,
      operation_id: operation.id,
      node_id: operation.node_id,
      instance_id: operation.instance_id,
      placement_revision: operation.placement_revision,
      action: operation.action,
      args: args
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

        if operation.action == "provision_node", do: Repo.rollback(:local_operation)

        if operation.instance_id && !current_placement?(operation) &&
             !(operation.action == "instance_delete" && operation.status == "ok"),
           do: Repo.rollback(:stale_placement)

        operation = transition(operation, event, payload)

        if event == "command_result" and operation.action == "instance_delete" and
             operation.status == "ok" do
          if operation.result["deleted"] != true or
               operation.result["instance_id"] != operation.instance_id,
             do: Repo.rollback(:invalid_delete_result)

          Repo.update_all(
            from(p in Placement,
              where: p.id == ^operation.placement_id and p.state == "active"
            ),
            set: [state: "retired"]
          )
        end

        operation
      end)

    case result do
      {:ok, operation} ->
        if event == "command_result" and operation.action in ~w(backup backup_database),
          do: Bastion.ManagedSnapshots.operation_finished(operation)

        if event == "command_result" and operation.action in ~w(domain_prepare domain_release) do
          %{operation_id: operation.id}
          |> Bastion.Domains.FinalizeWorker.new()
          |> Oban.insert()
        end

        if event == "command_result" and
             operation.action in ~w(instance_create domain_activate domain_rollback) do
          %{operation_id: operation.id}
          |> Bastion.ManagedInstances.FinalizeWorker.new()
          |> Oban.insert()
        end

        broadcast()
        {:ok, operation}

      error ->
        error
    end
  end

  def store_bootstrap_credentials(node_id, %{
        "instance_id" => instance_id,
        "placement_revision" => revision,
        "admin_login" => login,
        "admin_password" => password
      })
      when is_integer(revision) and revision > 0 and is_binary(login) and
             is_binary(password) do
    with {:ok, instance_id} <- Ecto.UUID.cast(instance_id),
         true <-
           byte_size(login) in 1..255 and byte_size(password) in 16..1024 and
             String.valid?(login) and String.valid?(password) do
      Repo.transaction(fn ->
        placement =
          Repo.one(
            from p in Placement,
              where:
                p.instance_id == ^instance_id and p.node_id == ^node_id and
                  p.revision == ^revision and p.state == "active",
              lock: "FOR UPDATE"
          ) || Repo.rollback(:stale_placement)

        if !Repo.exists?(
             from o in Operation,
               where:
                 o.instance_id == ^instance_id and o.placement_id == ^placement.id and
                   o.action == "instance_create" and
                   (o.status in ["pending", "running", "unknown", "ok"] or
                      (o.status == "waiting_external" and
                         fragment("?->>'stage' = 'verifying'", o.progress) and
                         fragment("?->>'stage' = 'ready'", o.result)))
           ),
           do: Repo.rollback(:creation_not_dispatched)

        instance = Repo.one!(from i in Instance, where: i.id == ^instance_id, lock: "FOR UPDATE")
        if instance.transport != "node", do: Repo.rollback(:not_managed)

        cond do
          is_nil(instance.admin_password_encrypted) ->
            instance
            |> Ecto.Changeset.change(
              admin_login: login,
              admin_password_encrypted: Bastion.Credentials.encrypt(password)
            )
            |> Repo.update!()

          instance.admin_login == login and
              credential_equal?(instance.admin_password_encrypted, password) ->
            instance

          true ->
            Repo.rollback(:credential_conflict)
        end
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :invalid_credentials}
    end
  end

  def store_bootstrap_credentials(_, _), do: {:error, :invalid_credentials}

  defp credential_equal?(encrypted, password) do
    case Bastion.Credentials.decrypt(encrypted) do
      {:ok, previous} when byte_size(previous) == byte_size(password) ->
        Plug.Crypto.secure_compare(previous, password)

      _ ->
        false
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

        infrastructure = payload["infrastructure"]

        infrastructure =
          if is_map(infrastructure) and is_boolean(infrastructure["ready"]),
            do: infrastructure,
            else: %{}

        current
        |> Ecto.Changeset.change(
          [
            last_seen_at: now,
            version: version,
            infrastructure: infrastructure,
            install_status:
              cond do
                infrastructure["ready"] == true and not is_nil(current.credential_hash) -> "ready"
                current.install_status == "ready" -> "waiting_dependencies"
                true -> current.install_status
              end
          ] ++ observation
        )
        |> Repo.update!()

        if infrastructure["ready"] == true and not is_nil(current.credential_hash) do
          case Repo.one(
                 from o in Operation,
                   where:
                     o.node_id == ^node.id and o.action == "provision_node" and
                       o.status == "waiting_external",
                   order_by: [desc: o.inserted_at],
                   limit: 1
               ) do
            nil ->
              :ok

            operation ->
              operation
              |> Ecto.Changeset.change(
                status: "ok",
                result: %{"ready" => true},
                progress: %{"stage" => "ready"},
                finished_at: now
              )
              |> Repo.update!()
          end
        end

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
    if operation.status in @unresolved and operation.progress["stage"] != "verifying" do
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
    if operation.status == "waiting_external" and operation.progress["stage"] == "verifying" do
      operation
    else
      transition_result(operation, status, payload)
    end
  end

  defp transition(_operation, _, _), do: Repo.rollback(:invalid_transition)

  defp transition_result(operation, status, payload) do
    if operation.status in @unresolved do
      finished_at = if status == "unknown", do: nil, else: DateTime.utc_now()
      result = if is_map(payload["result"]), do: payload["result"], else: %{}

      verifying =
        status == "ok" and
          operation.action in ~w(instance_create domain_activate domain_rollback)

      operation
      |> Ecto.Changeset.change(
        status: if(verifying, do: "waiting_external", else: status),
        result: result,
        progress:
          if(verifying,
            do: Map.put(operation.progress, "stage", "verifying"),
            else: operation.progress
          ),
        finished_at: if(verifying, do: nil, else: finished_at)
      )
      |> Repo.update!()
    else
      operation
    end
  end

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
