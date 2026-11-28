defmodule Bastion.ManagedMove do
  @moduledoc "Reserve and adopt a restored installation on another managed node."

  import Ecto.Query

  alias Bastion.{ManagedSnapshots, Nodes, Repo}
  alias Bastion.Domains.{Binding, HttpsProbe, PublicDNS}
  alias Bastion.Instances.Instance
  alias Bastion.Nodes.{Node, Operation, Placement}

  @unresolved ~w(pending running waiting_external unknown)
  @sha ~r/\A[0-9a-f]{64}\z/

  def pending(instance_id) do
    Repo.one(
      from o in Operation,
        where:
          o.instance_id == ^instance_id and o.action == "instance_move" and
            o.status == "waiting_external",
        order_by: [desc: o.inserted_at],
        limit: 1
    )
  end

  def reserve(instance_id, target_node_id, port, mode, evidence, actor)
      when mode in ~w(planned disaster) and is_binary(actor) and is_integer(port) and
             port in 1024..65_535 do
    with {:ok, instance_id} <- Ecto.UUID.cast(instance_id),
         {:ok, target_node_id} <- Ecto.UUID.cast(target_node_id) do
      Repo.transaction(fn ->
        instance = Repo.one(from i in Instance, where: i.id == ^instance_id, lock: "FOR UPDATE")
        if is_nil(instance) or instance.transport != "node", do: Repo.rollback(:not_managed)

        source =
          Repo.one(
            from p in Placement,
              where: p.instance_id == ^instance_id and p.state == "active",
              lock: "FOR UPDATE",
              preload: :node
          ) || Repo.rollback(:source_not_found)

        if source.node_id == target_node_id, do: Repo.rollback(:same_node)

        target =
          Repo.one(from n in Node, where: n.id == ^target_node_id, lock: "FOR UPDATE") ||
            Repo.rollback(:target_not_found)

        if target.maintenance or not Nodes.ready?(target), do: Repo.rollback(:target_unavailable)
        if addresses(target) == [], do: Repo.rollback(:target_address_missing)
        if not connected_addresses?(instance), do: Repo.rollback(:public_addresses_missing)

        if Repo.exists?(
             from o in Operation,
               where: o.instance_id == ^instance_id and o.status in ^@unresolved
           ),
           do: Repo.rollback(:busy)

        snapshot = ManagedSnapshots.latest(instance_id) || Repo.rollback(:snapshot_missing)

        if is_nil(snapshot.integrity_checked_at) or
             not Regex.match?(@sha, snapshot.checksum || ""),
           do: Repo.rollback(:snapshot_unverified)

        case mode do
          "planned" -> require_planned_fence!(instance, source, snapshot)
          "disaster" -> require_disaster_fence!(source, evidence)
        end

        revision =
          (Repo.one(
             from p in Placement, where: p.instance_id == ^instance_id, select: max(p.revision)
           ) || 0) + 1

        project_name = "delivest-" <> String.replace(instance_id, "-", "")

        placement =
          %Placement{instance_id: instance_id, node_id: target.id}
          |> Placement.changeset(%{
            revision: revision,
            project_name: project_name,
            gateway_port: port,
            state: "reserved"
          })
          |> Repo.insert()
          |> case do
            {:ok, placement} -> placement
            {:error, _} -> Repo.rollback(:target_resources_reserved)
          end

        operation =
          %Operation{
            node_id: source.node_id,
            instance_id: instance_id,
            placement_id: source.id,
            placement_revision: source.revision
          }
          |> Operation.changeset(%{
            action: "instance_move",
            status: "waiting_external",
            requested_by: actor,
            args: %{
              "target_placement_id" => placement.id,
              "snapshot_id" => snapshot.id,
              "snapshot_sha256" => snapshot.checksum,
              "mode" => mode,
              "fence_evidence" => if(mode == "disaster", do: String.trim(evidence), else: "")
            }
          })
          |> Repo.insert!()

        operation
      end)
      |> notify()
    else
      _ -> {:error, :invalid_target}
    end
  end

  def reserve(_, _, _, _, _, _), do: {:error, :invalid_request}

  def confirm(operation_id, actor) when is_binary(actor) do
    with %Operation{action: "instance_move", status: "waiting_external"} = operation <-
           Repo.get(Operation, operation_id),
         %Placement{} = target <-
           Repo.get(Placement, operation.args["target_placement_id"]) |> Repo.preload(:node),
         %Instance{} = instance <- Repo.get(Instance, operation.instance_id),
         :ok <- target_ready(target),
         :ok <- probe().check(instance, target.node) do
      Repo.transaction(fn -> confirm_locked!(operation.id, target.id, actor) end)
      |> notify()
    else
      {:error, _} = error -> error
      _ -> {:error, :move_not_pending}
    end
  end

  def confirm(_, _), do: {:error, :invalid_request}

  def cancel(operation_id, actor, "target_removed_and_fenced", evidence)
      when is_binary(actor) and is_binary(evidence) and byte_size(evidence) >= 10 do
    Repo.transaction(fn ->
      operation = lock_pending!(operation_id)
      target = lock_target!(operation)
      if not is_nil(target.observed_at), do: Repo.rollback(:target_already_observed)

      target |> Ecto.Changeset.change(state: "retired") |> Repo.update!()

      operation
      |> Ecto.Changeset.change(
        status: "error",
        result: %{
          "reason" => "reservation cancelled before target start",
          "actor" => actor,
          "target_removal_evidence" => String.trim(evidence)
        },
        finished_at: DateTime.utc_now()
      )
      |> Repo.update!()
    end)
    |> notify()
  end

  def cancel(_, _, _, _), do: {:error, :confirmation_required}

  def instructions(%Operation{action: "instance_move"} = operation) do
    target = Repo.get!(Placement, operation.args["target_placement_id"]) |> Repo.preload(:node)
    instance = Repo.get!(Instance, operation.instance_id)
    ips = addresses(target.node)

    bindings =
      Repo.all(
        from b in Binding,
          where: b.instance_id == ^instance.id and b.state == "connected",
          preload: :domain
      )
      |> Enum.map(fn binding ->
        %{
          "hostname" => binding.domain.hostname,
          "binding_id" => binding.id,
          "purpose" => binding.purpose,
          "routing" => binding.routing,
          "expected_addresses" => ips
        }
      end)

    payload = %{
      "operation_id" => operation.id,
      "instance_id" => instance.id,
      "placement_revision" => target.revision,
      "primary_hostname" => instance.hosts["site"],
      "bindings" => bindings
    }

    %{
      operation: operation,
      target: target,
      snapshot_id: operation.args["snapshot_id"],
      snapshot_sha256: operation.args["snapshot_sha256"],
      prepare_base64: payload |> Jason.encode!() |> Base.encode64()
    }
  end

  def check(%Instance{} = instance, node) do
    ips = addresses(node)

    Enum.reduce_while(~w(site api media), :ok, fn purpose, _ ->
      hostname = instance.hosts[purpose]

      binding =
        Repo.one(
          from b in Binding,
            join: d in assoc(b, :domain),
            where:
              b.instance_id == ^instance.id and b.state == "connected" and
                b.purpose == ^purpose and d.hostname == ^hostname,
            limit: 1
        )

      result =
        with true <- is_binary(hostname) and ips != [] and not is_nil(binding),
             {:ok, _} <- PublicDNS.check(hostname, ips),
             {:ok, _} <- HttpsProbe.check(hostname, binding.id, ips, purpose) do
          :ok
        else
          _ -> {:error, :destination_public_check_failed}
        end

      if result == :ok, do: {:cont, :ok}, else: {:halt, result}
    end)
  end

  defp confirm_locked!(id, target_id, actor) do
    operation = lock_pending!(id)

    source =
      Repo.one!(
        from p in Placement,
          where: p.id == ^operation.placement_id,
          lock: "FOR UPDATE",
          preload: :node
      )

    target = lock_target!(operation)

    instance =
      Repo.one!(from i in Instance, where: i.id == ^operation.instance_id, lock: "FOR UPDATE")

    if target.id != target_id or source.state != "active" or target.state != "reserved",
      do: Repo.rollback(:placement_changed)

    if target.instance_id != source.instance_id or target.revision <= source.revision,
      do: Repo.rollback(:placement_changed)

    if is_nil(instance) or instance.transport != "node", do: Repo.rollback(:not_managed)
    if target_ready(target) != :ok, do: Repo.rollback(:target_not_ready)

    snapshot = ManagedSnapshots.latest(instance.id)

    if is_nil(snapshot) or snapshot.id != operation.args["snapshot_id"] or
         snapshot.checksum != operation.args["snapshot_sha256"],
       do: Repo.rollback(:snapshot_changed)

    expected_version = snapshot.release_compatibility["release_version"]

    if is_binary(expected_version) and target.observed_release != expected_version,
      do: Repo.rollback(:target_release_mismatch)

    case operation.args["mode"] do
      "planned" -> require_planned_fence!(instance, source, snapshot)
      "disaster" -> require_disaster_fence!(source, operation.args["fence_evidence"])
      _ -> Repo.rollback(:invalid_mode)
    end

    source |> Ecto.Changeset.change(state: "retired") |> Repo.update!()
    target |> Ecto.Changeset.change(state: "active") |> Repo.update!()

    instance
    |> Ecto.Changeset.change(desired_state: "running", desired_release: target.observed_release)
    |> Repo.update!()

    operation
    |> Ecto.Changeset.change(
      status: "ok",
      result: %{"target_placement_id" => target.id, "actor" => actor},
      finished_at: DateTime.utc_now()
    )
    |> Repo.update!()
  end

  defp lock_pending!(id) do
    operation = Repo.one(from o in Operation, where: o.id == ^id, lock: "FOR UPDATE")

    if is_nil(operation) or operation.action != "instance_move" or
         operation.status != "waiting_external",
       do: Repo.rollback(:move_not_pending)

    operation
  end

  defp lock_target!(operation) do
    Repo.one(
      from p in Placement,
        where: p.id == ^operation.args["target_placement_id"],
        lock: "FOR UPDATE",
        preload: :node
    ) ||
      Repo.rollback(:target_not_found)
  end

  defp require_planned_fence!(instance, source, snapshot) do
    stopped =
      Repo.one(
        from o in Operation,
          where:
            o.instance_id == ^instance.id and o.placement_id == ^source.id and
              o.action == "stop" and o.status == "ok",
          order_by: [desc: o.finished_at],
          limit: 1
      )

    if instance.desired_state != "stopped" or source.observed_state != "stopped" or
         is_nil(source.observed_at) or DateTime.diff(DateTime.utc_now(), source.observed_at) > 120 or
         not Nodes.ready?(source.node) or is_nil(stopped) or stopped.result["fenced"] != true or
         DateTime.compare(snapshot.inserted_at, stopped.finished_at) != :gt,
       do: Repo.rollback(:source_not_fenced)
  end

  defp require_disaster_fence!(source, evidence) do
    if Bastion.Fleet.connected?(source.node) or not is_binary(evidence) or
         byte_size(String.trim(evidence)) < 10,
       do: Repo.rollback(:external_fence_required)
  end

  defp target_ready(%Placement{
         node: node,
         state: "reserved",
         observed_state: "running",
         observed_at: at,
         observed_release: version
       })
       when is_binary(version) and not is_nil(at) do
    if Nodes.ready?(node) and DateTime.diff(DateTime.utc_now(), at) <= 90,
      do: :ok,
      else: {:error, :target_not_ready}
  end

  defp target_ready(_), do: {:error, :target_not_ready}

  defp addresses(node),
    do: [node.public_ipv4, node.public_ipv6] |> Enum.reject(&is_nil/1)

  defp connected_addresses?(instance) do
    Enum.all?(~w(site api media), fn purpose ->
      hostname = instance.hosts[purpose]

      is_binary(hostname) and
        Repo.exists?(
          from b in Binding,
            join: d in assoc(b, :domain),
            where:
              b.instance_id == ^instance.id and b.state == "connected" and
                b.purpose == ^purpose and d.hostname == ^hostname
        )
    end)
  end

  defp probe, do: Application.get_env(:bastion, :move_probe, __MODULE__)

  defp notify({:ok, _} = result) do
    Phoenix.PubSub.broadcast(Bastion.PubSub, "managed_nodes", :nodes_updated)
    result
  end

  defp notify(result), do: result
end
