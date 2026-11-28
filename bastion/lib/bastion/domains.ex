defmodule Bastion.Domains do
  import Ecto.Query

  alias Bastion.Domains.{Binding, Domain}
  alias Bastion.Repo
  alias Bastion.Nodes

  def list_domains,
    do: Repo.all(from d in Domain, preload: [bindings: [:instance]], order_by: [asc: d.hostname])

  def create_domain(attrs) do
    %Domain{} |> Domain.changeset(attrs) |> Repo.insert()
  end

  def get_domain(id) do
    case Repo.get(Domain, id) do
      nil -> nil
      domain -> Repo.preload(domain, [:bindings])
    end
  end

  def bindings_for(instance_id) do
    Repo.all(
      from b in Binding,
        where: b.instance_id == ^instance_id and b.state != "released",
        preload: [:domain]
    )
  end

  def reserve(domain_id, instance_id, purpose, primary \\ false) do
    case reserve_with_proof(domain_id, instance_id, purpose, primary) do
      {:ok, {binding, _proof}} -> {:ok, binding}
      error -> error
    end
  end

  def reserve_with_proof(domain_id, instance_id, purpose, primary \\ false) do
    Repo.transaction(fn ->
      domain =
        Repo.one(from d in Domain, where: d.id == ^domain_id, lock: "FOR UPDATE") ||
          Repo.rollback(:domain_not_found)

      if Repo.exists?(
           from b in Binding, where: b.domain_id == ^domain.id and b.state != "released"
         ),
         do: Repo.rollback(:already_bound)

      token =
        if domain.dns_mode in ~w(external manual),
          do: Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

      verification_name = if token, do: "_delivest-verification." <> domain.hostname

      expected =
        case expected_addresses(instance_id) do
          {:ok, addresses} -> %{"addresses" => addresses}
          _ -> %{}
        end

      changeset =
        %Binding{domain_id: domain.id, instance_id: instance_id}
        |> Binding.changeset(%{purpose: purpose, primary: primary, state: "reserved"})
        |> Ecto.Changeset.put_change(
          :verification_token_hash,
          if(token, do: :crypto.hash(:sha256, token))
        )
        |> Ecto.Changeset.put_change(:verification_name, verification_name)
        |> Ecto.Changeset.put_change(:expected_records, expected)

      case Repo.insert(changeset) do
        {:ok, binding} ->
          domain |> Ecto.Changeset.change(state: "reserved") |> Repo.update!()
          {binding, token}

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  def release(binding_id) do
    :global.trans({{__MODULE__, binding_id}, self()}, fn -> do_release(binding_id) end)
  end

  defp do_release(binding_id) do
    Repo.transaction(fn ->
      binding =
        Repo.one(from b in Binding, where: b.id == ^binding_id, lock: "FOR UPDATE") ||
          Repo.rollback(:binding_not_found)

      if binding.state not in ~w(reserved waiting_dns) or binding.owned_records != %{},
        do: Repo.rollback(:connected_address_requires_node_release)

      updated =
        binding
        |> Ecto.Changeset.change(state: "released", verification_token_hash: nil)
        |> Repo.update!()

      set_domain_state(binding.domain_id, "free")
      updated
    end)
  end

  def expected_addresses(instance_id) do
    with %{node: node} <- Nodes.placement_for(instance_id),
         addresses <- [node.public_ipv4, node.public_ipv6] |> Enum.reject(&is_nil/1),
         true <- addresses != [] do
      {:ok, addresses}
    else
      _ -> {:error, :node_public_address_missing}
    end
  end

  def request_prepare(binding_id, proof, requested_by) do
    :global.trans({{__MODULE__, binding_id}, self()}, fn ->
      do_request_prepare(binding_id, proof, requested_by)
    end)
  end

  defp do_request_prepare(binding_id, proof, requested_by) do
    with %Binding{state: state} = binding when state in ~w(reserved waiting_dns error) <-
           get_binding(binding_id),
         {:ok, addresses} <- expected_addresses(binding.instance_id),
         :ok <- store_expected(binding, addresses),
         :ok <- ownership_confirmed?(binding, proof),
         :ok <- provision_managed_records(binding, addresses),
         {:ok, observed} <- Bastion.Domains.PublicDNS.check(binding.domain.hostname, addresses),
         {:ok, operation} <- queue_prepare(binding, requested_by, addresses, observed) do
      Nodes.dispatch_operation(operation)
      {:ok, operation}
    else
      {:error, {:dns_mismatch, observed}} ->
        if binding = Repo.get(Binding, binding_id) do
          binding
          |> Ecto.Changeset.change(
            state: "waiting_dns",
            observed_records: observed,
            failure_reason: "DNS не совпадает",
            next_step: "Опубликуйте ожидаемые A/AAAA записи"
          )
          |> Repo.update!()

          set_domain_state(binding.domain_id, "waiting_dns")
        end

        {:error, :waiting_dns}

      {:error, :ownership_unconfirmed} ->
        mark_binding(
          binding_id,
          "waiting_dns",
          "TXT подтверждение не найдено",
          "Опубликуйте TXT запись подтверждения"
        )

        {:error, :waiting_dns}

      {:error, reason} = error
      when reason in [
             :provider_unavailable,
             :credentials_unavailable,
             :dns_access_unconfirmed,
             :write_outcome_uncertain,
             :rate_limited
           ] ->
        mark_binding(
          binding_id,
          "error",
          "DNS-провайдер недоступен",
          "Проверьте доступ и повторите"
        )

        error

      other ->
        other
    end
  end

  defp store_expected(binding, addresses) do
    binding
    |> Ecto.Changeset.change(expected_records: %{"addresses" => addresses})
    |> Repo.update!()

    :ok
  end

  defp mark_binding(id, state, reason, next_step) do
    if binding = Repo.get(Binding, id) do
      binding
      |> Ecto.Changeset.change(
        state: state,
        failure_reason: reason,
        next_step: next_step,
        last_checked_at: DateTime.utc_now()
      )
      |> Repo.update!()

      set_domain_state(binding.domain_id, state)
    end
  end

  defp queue_prepare(binding, requested_by, addresses, observed) do
    Repo.transaction(fn ->
      current = Repo.one!(from b in Binding, where: b.id == ^binding.id, lock: "FOR UPDATE")

      if current.state not in ~w(reserved waiting_dns error) or
           current.instance_id != binding.instance_id,
         do: Repo.rollback(:binding_changed)

      args = %{
        "hostname" => binding.domain.hostname,
        "purpose" => binding.purpose,
        "binding_id" => binding.id,
        "expected_addresses" => addresses
      }

      operation =
        case Nodes.queue_deferred(binding.instance_id, "domain_prepare", requested_by, args) do
          {:ok, operation} -> operation
          {:error, reason} -> Repo.rollback(reason)
        end

      current
      |> Ecto.Changeset.change(
        state: "preparing_https",
        active_operation_id: operation.id,
        expected_records: %{"addresses" => addresses},
        observed_records: observed,
        last_checked_at: DateTime.utc_now()
      )
      |> Repo.update!()

      set_domain_state(binding.domain_id, "preparing_https")
      operation
    end)
  end

  def request_release(binding_id, requested_by) do
    :global.trans({{__MODULE__, binding_id}, self()}, fn ->
      do_request_release(binding_id, requested_by)
    end)
  end

  defp do_request_release(binding_id, requested_by) do
    with %Binding{} = binding <- get_binding(binding_id) do
      if binding.state in ~w(reserved waiting_dns) and binding.owned_records == %{} do
        do_release(binding_id)
      else
        with {:ok, addresses} <- expected_addresses(binding.instance_id),
             {:ok, operation} <-
               Repo.transaction(fn ->
                 args = %{
                   "hostname" => binding.domain.hostname,
                   "purpose" => binding.purpose,
                   "binding_id" => binding.id,
                   "expected_addresses" => addresses
                 }

                 operation =
                   case Nodes.queue_deferred(
                          binding.instance_id,
                          "domain_release",
                          requested_by,
                          args
                        ) do
                     {:ok, operation} -> operation
                     {:error, reason} -> Repo.rollback(reason)
                   end

                 binding
                 |> Ecto.Changeset.change(active_operation_id: operation.id)
                 |> Repo.update!()

                 operation
               end) do
          Nodes.dispatch_operation(operation)
          {:ok, operation}
        end
      end
    else
      _ -> {:error, :binding_not_found}
    end
  end

  def complete_operation(
        %Bastion.Nodes.Operation{action: "domain_release", status: "ok", args: args} = operation
      ) do
    case get_binding(args["binding_id"]) do
      %Binding{active_operation_id: id} when id == operation.id ->
        :global.trans({{__MODULE__, args["binding_id"]}, self()}, fn ->
          do_complete_release(operation)
        end)

      _ ->
        :ok
    end
  end

  def complete_operation(
        %Bastion.Nodes.Operation{action: "domain_prepare", status: "ok", args: args} = operation
      ) do
    case get_binding(args["binding_id"]) do
      %Binding{active_operation_id: id} when id == operation.id -> do_complete_prepare(operation)
      _ -> :ok
    end
  end

  def complete_operation(
        %Bastion.Nodes.Operation{
          action: "domain_prepare",
          status: "error",
          args: args,
          result: result
        } = operation
      ) do
    case Repo.get(Binding, args["binding_id"]) do
      %Binding{active_operation_id: id} = binding when id == operation.id ->
        binding
        |> Ecto.Changeset.change(
          state: "error",
          failure_reason: result["reason"] || "Не удалось подготовить HTTPS",
          next_step: "Исправьте причину и повторите"
        )
        |> Repo.update()

        set_domain_state(binding.domain_id, "error")

      _ ->
        :ok
    end
  end

  def complete_operation(
        %Bastion.Nodes.Operation{
          action: "domain_release",
          status: "error",
          args: args,
          result: result
        } = operation
      ) do
    case Repo.get(Binding, args["binding_id"]) do
      %Binding{active_operation_id: id} = binding when id == operation.id ->
        binding
        |> Ecto.Changeset.change(
          state: "error",
          failure_reason: result["reason"] || "Не удалось освободить адрес",
          next_step: "Проверьте маршрут и повторите"
        )
        |> Repo.update()

        set_domain_state(binding.domain_id, "error")

      _ ->
        :ok
    end
  end

  def complete_operation(_), do: :ok

  defp do_complete_release(
         %Bastion.Nodes.Operation{args: args, instance_id: instance_id, result: result} =
           operation
       ) do
    with %Binding{} = binding <- get_binding(args["binding_id"]),
         true <-
           binding.instance_id == instance_id and binding.domain.hostname == args["hostname"] and
             binding.active_operation_id == operation.id,
         true <-
           result["released"] == true and result["binding_id"] == binding.id and
             result["hostname"] == binding.domain.hostname,
         :ok <- remove_owned_records(binding) do
      Repo.transaction(fn ->
        current = Repo.one!(from b in Binding, where: b.id == ^binding.id, lock: "FOR UPDATE")
        if current.active_operation_id != operation.id, do: Repo.rollback(:stale_operation)

        updated =
          current
          |> Ecto.Changeset.change(
            state: "released",
            active_operation_id: nil,
            verification_token_hash: nil,
            owned_records: %{}
          )
          |> Repo.update!()

        set_domain_state(binding.domain_id, "free")
        updated
      end)
    else
      _ -> {:error, :release_unconfirmed}
    end
  end

  defp do_complete_prepare(
         %Bastion.Nodes.Operation{instance_id: instance_id, args: args, result: result} =
           operation
       ) do
    with %Binding{} = binding <- get_binding(args["binding_id"]),
         true <-
           binding.instance_id == instance_id and binding.state in ~w(preparing_https checking) and
             binding.active_operation_id == operation.id,
         true <- binding.domain.hostname == args["hostname"],
         %{revision: revision} <- Nodes.placement_for(instance_id),
         true <- revision == operation.placement_revision,
         true <-
           result["verified"] == true and result["binding_id"] == binding.id and
             result["hostname"] == binding.domain.hostname,
         {:ok, observation} <-
           Bastion.Domains.HttpsProbe.check(
             binding.domain.hostname,
             binding.id,
             args["expected_addresses"],
             binding.purpose
           ) do
      outcome =
        Repo.transaction(fn ->
          current = Repo.one!(from b in Binding, where: b.id == ^binding.id, lock: "FOR UPDATE")

          if current.active_operation_id != operation.id or
               current.state not in ~w(preparing_https checking),
             do: Repo.rollback(:stale_operation)

          current
          |> Ecto.Changeset.change(
            state: "connected",
            active_operation_id: nil,
            observed_records: Map.put(current.observed_records, "https", observation),
            certificate_expires_at: parse_expiry(result["certificate_expires_at"]),
            last_checked_at: DateTime.utc_now(),
            failure_reason: nil,
            next_step: nil
          )
          |> Repo.update!()
        end)

      if match?({:ok, _}, outcome), do: set_domain_state(binding.domain_id, "connected")
      outcome
    else
      _ ->
        case Repo.get(Binding, args["binding_id"]) do
          %Binding{active_operation_id: id} = binding when id == operation.id ->
            binding
            |> Ecto.Changeset.change(
              state: "error",
              failure_reason: "HTTPS проверка не прошла",
              next_step: "Проверьте сертификат и маршрут"
            )
            |> Repo.update()

            set_domain_state(binding.domain_id, "error")

          _ ->
            :ok
        end

        {:error, :https_unverified}
    end
  end

  defp get_binding(id) do
    case Repo.get(Binding, id) do
      nil -> nil
      binding -> Repo.preload(binding, :domain)
    end
  end

  defp parse_expiry(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _} -> %{at | microsecond: {elem(at.microsecond, 0), 6}}
      _ -> nil
    end
  end

  defp parse_expiry(_), do: nil

  defp set_domain_state(id, state),
    do:
      Repo.update_all(from(d in Domain, where: d.id == ^id),
        set: [state: state, observed_at: DateTime.utc_now()]
      )

  defp ownership_confirmed?(%Binding{domain: %{dns_mode: mode}} = binding, _proof)
       when mode in ~w(external manual) do
    if is_binary(binding.verification_token_hash),
      do:
        Bastion.Domains.PublicDNS.check_txt_hash(
          binding.verification_name,
          binding.verification_token_hash
        ),
      else: {:error, :ownership_unconfirmed}
  end

  defp ownership_confirmed?(
         %Binding{domain: %{dns_mode: "regru", zone: zone, hostname: hostname}},
         _
       )
       when is_binary(zone) do
    if hostname == zone or String.ends_with?(hostname, "." <> zone) do
      case Bastion.Domains.RegRu.records(zone) do
        {:ok, _} -> :ok
        _ -> {:error, :dns_access_unconfirmed}
      end
    else
      {:error, :dns_zone_mismatch}
    end
  end

  defp ownership_confirmed?(_, _), do: {:error, :dns_access_unconfirmed}

  defp provision_managed_records(
         %Binding{domain: %{dns_mode: "regru", zone: zone, hostname: hostname}} = binding,
         addresses
       ) do
    subdomain = if hostname == zone, do: "@", else: String.trim_trailing(hostname, "." <> zone)

    Enum.reduce_while(addresses, :ok, fn address, _ ->
      type = if String.contains?(address, ":"), do: "AAAA", else: "A"

      case Bastion.Domains.RegRu.add(zone, subdomain, type, address) do
        {:ok, :already_present} ->
          {:cont, :ok}

        {:ok, _} ->
          current = Repo.get!(Binding, binding.id)
          owned = Map.get(current.owned_records, type, []) |> Enum.uniq()

          current
          |> Ecto.Changeset.change(
            owned_records: Map.put(current.owned_records, type, Enum.uniq([address | owned]))
          )
          |> Repo.update!()

          {:cont, :ok}

        error ->
          {:halt, error}
      end
    end)
  end

  defp provision_managed_records(_, _), do: :ok

  defp remove_owned_records(%Binding{
         domain: %{dns_mode: "regru", zone: zone, hostname: hostname},
         owned_records: owned
       }) do
    subdomain = if hostname == zone, do: "@", else: String.trim_trailing(hostname, "." <> zone)

    Enum.reduce_while(owned, :ok, fn {type, values}, _ ->
      Enum.reduce_while(values, :ok, fn value, _ ->
        case Bastion.Domains.RegRu.remove(zone, subdomain, type, value) do
          {:ok, _} -> {:cont, :ok}
          error -> {:halt, error}
        end
      end)
      |> case do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp remove_owned_records(_), do: :ok
end
