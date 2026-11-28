defmodule Bastion.ManagedInstances do
  @moduledoc "Creation and domain changes for Node-managed franchises."
  import Ecto.Query

  alias Bastion.{Domains, Nodes, Repo}
  alias Bastion.Domains.{Binding, Domain}
  alias Bastion.Instances.Instance
  alias Bastion.Nodes.Operation

  @slug ~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/

  def create(attrs, actor) when is_map(attrs) do
    with {:ok, attrs} <- normalize(attrs),
         {:ok, release} <- Bastion.Releases.Managed.latest() do
      reserve(attrs, release, actor)
    end
  end

  def create(_, _), do: {:error, :invalid_input}

  defp normalize(attrs) do
    short = attrs["short_name"] |> to_string() |> String.trim() |> String.downcase()
    name = attrs["name"] |> to_string() |> String.trim()
    site = attrs["site_hostname"]

    site =
      if is_binary(site) and String.trim(site) != "",
        do: Domain.normalize(site),
        else: short <> ".delivest.ru"

    mode = if site == short <> ".delivest.ru", do: "regru", else: attrs["dns_mode"]
    zone = if mode == "regru", do: Domain.normalize(attrs["zone"] || "delivest.ru"), else: nil

    with true <- Regex.match?(@slug, short) and byte_size(name) in 1..255,
         true <- mode in ~w(regru external),
         true <-
           Domain.changeset(%Domain{}, %{hostname: site, dns_mode: mode, zone: zone}).valid?,
         {:ok, id} <- Ecto.UUID.cast(attrs["instance_id"]),
         {:ok, node_id} <- Ecto.UUID.cast(attrs["node_id"]) do
      {:ok,
       %{
         id: id,
         node_id: node_id,
         short: short,
         name: name,
         site: site,
         mode: mode,
         zone: zone,
         api: "api-#{short}.delivest.ru",
         media: "media-#{short}.delivest.ru"
       }}
    else
      _ -> {:error, :invalid_input}
    end
  end

  defp reserve(attrs, release, actor) do
    Repo.transaction(fn ->
      node =
        Repo.one(from n in Nodes.Node, where: n.id == ^attrs.node_id, lock: "FOR UPDATE") ||
          Repo.rollback(:node_not_found)

      if !Nodes.ready?(node) or node.maintenance, do: Repo.rollback(:node_not_ready)

      if Repo.get(Instance, attrs.id), do: Repo.rollback(:already_registered)

      if is_nil(node.public_ipv4) and is_nil(node.public_ipv6),
        do: Repo.rollback(:node_public_address_missing)

      port = free_port(node.id)
      project_name = "delivest-" <> String.replace(attrs.id, "-", "")

      hosts = %{
        "site" => attrs.site,
        "admin" => attrs.api,
        "api" => attrs.api,
        "media" => attrs.media
      }

      placement =
        case Nodes.prepare_instance(node.id, attrs.id, attrs.name, hosts, project_name, port) do
          {:ok, placement} -> placement
          {:error, reason} -> Repo.rollback(reason)
        end

      Repo.get!(Instance, attrs.id)
      |> Ecto.Changeset.change(desired_release: release.version, desired_state: "running")
      |> Repo.update!()

      {site, proof} = new_binding(attrs.site, attrs.mode, attrs.zone, attrs.id, "site", true)
      {api, _} = new_binding(attrs.api, "regru", "delivest.ru", attrs.id, "api", true)
      {media, _} = new_binding(attrs.media, "regru", "delivest.ru", attrs.id, "media", true)

      addresses = [node.public_ipv4, node.public_ipv6] |> Enum.reject(&is_nil/1)

      args = %{
        "release_url" => release.url,
        "release_sha256" => release.sha256,
        "release_version" => release.version,
        "gateway_port" => port,
        "site_hostname" => attrs.site,
        "admin_hostname" => attrs.api,
        "api_hostname" => attrs.api,
        "media_hostname" => attrs.media,
        "site_binding_id" => site.id,
        "admin_binding_id" => api.id,
        "api_binding_id" => api.id,
        "media_binding_id" => media.id,
        "expected_addresses" => addresses
      }

      operation =
        case Nodes.queue_deferred(attrs.id, "instance_create", actor, args) do
          {:ok, operation} -> operation
          {:error, reason} -> Repo.rollback(reason)
        end

      operation =
        operation
        |> Ecto.Changeset.change(
          status: "waiting_external",
          progress: %{"stage" => "waiting_dns"}
        )
        |> Repo.update!()

      {placement, operation, proof}
    end)
    |> case do
      {:ok, {_placement, operation, proof}} ->
        enqueue(operation.id)
        {:ok, operation, proof}

      error ->
        error
    end
  end

  defp free_port(node_id) do
    occupied =
      Repo.all(
        from p in Nodes.Placement,
          where: p.node_id == ^node_id and p.state != "retired",
          select: p.gateway_port
      )
      |> MapSet.new()

    Enum.find(20_000..60_000, &(not MapSet.member?(occupied, &1))) || Repo.rollback(:no_free_port)
  end

  defp new_binding(host, mode, zone, instance_id, purpose, primary) do
    domain =
      case %Domain{}
           |> Domain.changeset(%{hostname: host, dns_mode: mode, zone: zone})
           |> Repo.insert() do
        {:ok, domain} -> domain
        {:error, reason} -> Repo.rollback(reason)
      end

    case Domains.reserve_with_proof(domain.id, instance_id, purpose, primary) do
      {:ok, pair} -> pair
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  def retry_create(instance_id) do
    case Repo.one(
           from o in Operation,
             where: o.instance_id == ^instance_id and o.action == "instance_create",
             order_by: [desc: o.inserted_at],
             limit: 1
         ) do
      %Operation{status: status} = operation
      when status in ~w(waiting_external pending running unknown) ->
        enqueue(operation.id)
        {:ok, operation}

      %Operation{status: "error"} = operation ->
        with {:ok, resumed} <-
               Nodes.queue_deferred(
                 instance_id,
                 "instance_create",
                 operation.requested_by,
                 operation.args
               ) do
          resumed
          |> Ecto.Changeset.change(
            status: "waiting_external",
            progress: %{"stage" => "waiting_dns"}
          )
          |> Repo.update!()

          enqueue(resumed.id)
          {:ok, resumed}
        end

      _ ->
        {:error, :not_retryable}
    end
  end

  def advance_pending do
    Repo.all(
      from o in Operation,
        where: o.action == "instance_create" and o.status == "waiting_external",
        select: o.id,
        limit: 100
    )
    |> Enum.each(&advance/1)
  end

  def advance(operation_id) do
    :global.trans({{__MODULE__, operation_id}, self()}, fn -> do_advance(operation_id) end)
  end

  defp do_advance(operation_id) do
    case Repo.get(Operation, operation_id) do
      %Operation{action: "instance_create", status: "waiting_external"} = operation ->
        ids =
          Enum.uniq(
            Enum.map(~w(site_binding_id api_binding_id media_binding_id), &operation.args[&1])
          )

        case Enum.reduce_while(ids, :ok, fn id, _ ->
               case Domains.ensure_dns_for_create(id) do
                 :ok -> {:cont, :ok}
                 error -> {:halt, error}
               end
             end) do
          :ok ->
            operation
            |> Ecto.Changeset.change(status: "pending", progress: %{"stage" => "dns_ready"})
            |> Repo.update!()
            |> Nodes.dispatch_operation()

          {:error, :waiting_dns} ->
            record_wait(operation, "waiting_dns")
            :waiting_dns

          {:error, reason} ->
            record_wait(operation, "dns_error", reason)
            {:error, reason}
        end

      _ ->
        :ok
    end
  end

  defp record_wait(operation, stage, reason \\ nil) do
    progress = %{"stage" => stage}
    progress = if reason, do: Map.put(progress, "reason", inspect(reason)), else: progress
    operation |> Ecto.Changeset.change(progress: progress) |> Repo.update!()
  end

  defp enqueue(id),
    do: %{operation_id: id} |> Bastion.ManagedInstances.ProvisionWorker.new() |> Oban.insert()

  def bindings(instance_id), do: Domains.bindings_for(instance_id)

  def request_cleanup(instance_id, actor) do
    with %Operation{status: "error"} <-
           Repo.one(
             from o in Operation,
               where: o.instance_id == ^instance_id and o.action == "instance_create",
               order_by: [desc: o.inserted_at],
               limit: 1
           ),
         {:ok, operation} <-
           Nodes.queue(instance_id, "instance_cleanup", actor, %{
             "confirm_instance_id" => instance_id,
             "remove_data" => false
           }) do
      {:ok, operation}
    else
      _ -> {:error, :cleanup_requires_failed_installation}
    end
  end

  def confirm_browser(binding_id, actor) do
    with %Binding{purpose: "site", state: "connected", primary: false} = binding <-
           get_binding(binding_id),
         %Operation{status: "ok", action: "domain_prepare"} = prepare <-
           Repo.get(Operation, binding.observed_records["prepare_operation_id"]),
         true <-
           prepare.instance_id == binding.instance_id and prepare.args["binding_id"] == binding.id,
         {:ok, addresses} <- Domains.expected_addresses(binding.instance_id),
         {:ok, observation} <-
           Domains.HttpsProbe.check(binding.domain.hostname, binding.id, addresses, "site") do
      verification = %{
        "id" => Ecto.UUID.generate(),
        "prepare_operation_id" => prepare.id,
        "placement_revision" => prepare.placement_revision,
        "actor" => to_string(actor),
        "checked_url" => "https://" <> binding.domain.hostname <> "/",
        "checked_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "https" => observation,
        "browser_confirmed" => true
      }

      binding
      |> Ecto.Changeset.change(
        observed_records: Map.put(binding.observed_records, "browser_verification", verification)
      )
      |> Repo.update()
    else
      _ -> {:error, :not_prepared}
    end
  end

  def activate(binding_id, actor) do
    with %Binding{purpose: "site", state: "connected", primary: false} = binding <-
           get_binding(binding_id),
         %Binding{} = previous <-
           Repo.one(
             from b in Binding,
               where:
                 b.instance_id == ^binding.instance_id and b.purpose == "site" and b.primary and
                   b.state == "connected",
               preload: :domain
           ),
         %{
           "id" => verification_id,
           "prepare_operation_id" => prepare_id,
           "placement_revision" => revision
         } <-
           binding.observed_records["browser_verification"],
         %Operation{status: "ok", action: "domain_prepare", placement_revision: ^revision} <-
           Repo.get(Operation, prepare_id),
         %{revision: ^revision} <- Nodes.placement_for(binding.instance_id),
         false <- rollback_failed?(binding.instance_id),
         {:ok, operation} <-
           Nodes.queue_deferred(binding.instance_id, "domain_activate", actor, %{
             "hostname" => binding.domain.hostname,
             "binding_id" => binding.id,
             "purpose" => "site",
             "previous_hostname" => previous.domain.hostname,
             "previous_binding_id" => previous.id,
             "verification_id" => verification_id
           }) do
      Nodes.dispatch_operation(operation)
      {:ok, operation}
    else
      _ -> {:error, :not_verified}
    end
  end

  defp rollback_failed?(instance_id) do
    Repo.exists?(
      from o in Operation,
        where:
          o.instance_id == ^instance_id and o.action == "domain_rollback" and o.status == "error"
    )
  end

  defp get_binding(id) do
    case Repo.get(Binding, id) do
      nil -> nil
      binding -> Repo.preload(binding, :domain)
    end
  end
end
