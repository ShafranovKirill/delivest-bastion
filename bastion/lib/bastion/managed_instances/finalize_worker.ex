defmodule Bastion.ManagedInstances.FinalizeWorker do
  use Oban.Worker, queue: :default, max_attempts: 5
  import Ecto.Query

  alias Bastion.{Domains, Nodes, Repo}
  alias Bastion.Domains.Binding
  alias Bastion.Instances.Instance
  alias Bastion.Nodes.Operation

  @impl true
  def perform(%Oban.Job{args: %{"operation_id" => id}}) do
    case Repo.get(Operation, id) do
      %Operation{
        action: "instance_create",
        status: "waiting_external",
        progress: %{"stage" => "verifying"}
      } = operation ->
        finish(operation, &complete_create/1)

      %Operation{
        action: "domain_activate",
        status: "waiting_external",
        progress: %{"stage" => "verifying"}
      } = operation ->
        finish(operation, &complete_activation/1)

      %Operation{
        action: "domain_rollback",
        status: "waiting_external",
        progress: %{"stage" => "verifying"}
      } = operation ->
        finish(operation, &complete_rollback/1)

      _ ->
        :ok
    end
  end

  defp finish(operation, callback) do
    case callback.(operation) do
      :ok ->
        :ok

      {:error, reason} ->
        failed? =
          Repo.transaction(fn ->
            current = lock_operation(operation.id)

            if verifying?(current) do
              current
              |> Ecto.Changeset.change(
                status: "error",
                result: Map.put(current.result, "reason", inspect(reason)),
                progress: Map.put(current.progress, "stage", "verification_failed"),
                finished_at: DateTime.utc_now()
              )
              |> Repo.update!()

              true
            else
              false
            end
          end)

        if failed? == {:ok, true} and operation.action == "domain_activate" do
          case Nodes.queue(operation.instance_id, "domain_rollback", "system", operation.args) do
            {:ok, rollback} ->
              Nodes.dispatch_operation(rollback)

              Repo.update_all(from(o in Operation, where: o.id == ^operation.id),
                set: [
                  progress: %{
                    "stage" => "rollback_pending",
                    "rollback_operation_id" => rollback.id
                  }
                ]
              )

            {:error, rollback_reason} ->
              Repo.update_all(from(o in Operation, where: o.id == ^operation.id),
                set: [
                  progress: %{"stage" => "rollback_failed", "reason" => inspect(rollback_reason)}
                ]
              )
          end
        end

        :ok
    end
  end

  defp lock_operation(id),
    do: Repo.one!(from o in Operation, where: o.id == ^id, lock: "FOR UPDATE")

  defp verifying?(%Operation{status: "waiting_external", progress: %{"stage" => "verifying"}}),
    do: true

  defp verifying?(_), do: false

  defp finalize_operation(operation) do
    current = lock_operation(operation.id)

    if verifying?(current) do
      current
      |> Ecto.Changeset.change(
        status: "ok",
        progress:
          current.progress
          |> Map.put(
            "stage",
            if(current.action == "domain_rollback", do: "rolled_back", else: "ready")
          )
          |> Map.put("finalized", true),
        finished_at: DateTime.utc_now()
      )
      |> Repo.update!()

      :updated
    else
      :already_finalized
    end
  end

  defp complete_create(%Operation{args: args, result: result} = operation) do
    placement = Nodes.placement_for(operation.instance_id)

    with %{revision: revision, project_name: project, gateway_port: port} <- placement,
         true <- revision == operation.placement_revision,
         true <-
           result["stage"] == "ready" and result["instance_id"] == operation.instance_id and
             result["project_name"] == project and result["gateway_port"] == port and
             result["release_version"] == args["release_version"],
         :ok <- verify_hosts(args, operation.instance_id) do
      Repo.transaction(fn ->
        if not verifying?(lock_operation(operation.id)), do: Repo.rollback(:already_finalized)

        Enum.each(~w(site_binding_id api_binding_id media_binding_id), fn key ->
          binding = Repo.get!(Binding, args[key])

          if binding.instance_id != operation.instance_id or binding.state != "checking",
            do: Repo.rollback(:binding_changed)

          binding
          |> Ecto.Changeset.change(state: "connected", last_checked_at: DateTime.utc_now())
          |> Repo.update!()

          Repo.update_all(from(d in Domains.Domain, where: d.id == ^binding.domain_id),
            set: [state: "connected"]
          )
        end)

        Repo.get!(Instance, operation.instance_id)
        |> Ecto.Changeset.change(desired_state: "running")
        |> Repo.update!()

        finalize_operation(operation)
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, :already_finalized} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :creation_unverified}
    end
  end

  defp verify_hosts(args, instance_id) do
    Enum.reduce_while(~w(site api media), :ok, fn purpose, _ ->
      binding_id = args["#{purpose}_binding_id"]
      hostname = args["#{purpose}_hostname"]

      case Repo.get(Binding, binding_id) |> Repo.preload(:domain) do
        %Binding{instance_id: ^instance_id, domain: %{hostname: ^hostname}} ->
          case Domains.HttpsProbe.check(hostname, binding_id, args["expected_addresses"], purpose) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, :binding_target_mismatch}}
      end
    end)
  end

  defp complete_activation(%Operation{args: args, result: result} = operation) do
    new = Repo.get(Binding, args["binding_id"]) |> Repo.preload(:domain)
    old = Repo.get(Binding, args["previous_binding_id"]) |> Repo.preload(:domain)

    with %Binding{instance_id: id, state: "connected", primary: false} <- new,
         %Binding{instance_id: ^id, state: "connected", primary: true} <- old,
         true <-
           id == operation.instance_id and new.domain.hostname == args["hostname"] and
             old.domain.hostname == args["previous_hostname"],
         %{"id" => verification_id, "placement_revision" => revision} <-
           new.observed_records["browser_verification"],
         true <-
           verification_id == args["verification_id"] and revision == operation.placement_revision,
         true <-
           result["activated"] == true and result["binding_id"] == new.id and
             result["hostname"] == new.domain.hostname and
             result["previous_hostname"] == old.domain.hostname and
             result["previous_binding_id"] == old.id,
         {:ok, addresses} <- Domains.expected_addresses(id),
         {:ok, _} <- Domains.HttpsProbe.check(new.domain.hostname, new.id, addresses, "site"),
         :ok <- verify_stable_hosts(id, addresses),
         :ok <- redirect_ok?(old.domain.hostname, new.domain.hostname) do
      Repo.transaction(fn ->
        if not verifying?(lock_operation(operation.id)), do: Repo.rollback(:already_finalized)

        old = Repo.one!(from b in Binding, where: b.id == ^old.id, lock: "FOR UPDATE")
        new = Repo.one!(from b in Binding, where: b.id == ^new.id, lock: "FOR UPDATE")
        if !old.primary or new.primary, do: Repo.rollback(:primary_changed)

        old |> Ecto.Changeset.change(primary: false, routing: "redirect") |> Repo.update!()
        new |> Ecto.Changeset.change(primary: true, routing: "serve") |> Repo.update!()

        instance = Repo.get!(Instance, id)

        instance
        |> Ecto.Changeset.change(hosts: Map.put(instance.hosts || %{}, "site", args["hostname"]))
        |> Repo.update!()

        finalize_operation(operation)
      end)
      |> case do
        {:ok, _} -> :ok
        {:error, :already_finalized} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :activation_unverified}
    end
  end

  defp complete_rollback(%Operation{args: args, result: result} = operation) do
    old = Repo.get(Binding, args["previous_binding_id"]) |> Repo.preload(:domain)

    with %Binding{instance_id: id, primary: true, state: "connected"} <- old,
         true <- id == operation.instance_id and old.domain.hostname == args["previous_hostname"],
         true <- result["restored"] == true and result["previous_binding_id"] == old.id,
         {:ok, addresses} <- Domains.expected_addresses(id),
         {:ok, _} <- Domains.HttpsProbe.check(old.domain.hostname, old.id, addresses, "site"),
         :ok <- verify_stable_hosts(id, addresses) do
      Repo.transaction(fn -> finalize_operation(operation) end)
      |> case do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      _ -> {:error, :rollback_unverified}
    end
  end

  defp verify_stable_hosts(instance_id, addresses) do
    Enum.reduce_while(~w(api media), :ok, fn purpose, _ ->
      case Repo.one(
             from b in Binding,
               where:
                 b.instance_id == ^instance_id and b.purpose == ^purpose and
                   b.state == "connected",
               preload: :domain
           ) do
        %Binding{} = binding ->
          case Domains.HttpsProbe.check(binding.domain.hostname, binding.id, addresses, purpose) do
            {:ok, _} -> {:cont, :ok}
            error -> {:halt, error}
          end

        _ ->
          {:halt, {:error, :stable_address_missing}}
      end
    end)
  end

  defp redirect_ok?(old, new) do
    url = "https://#{old}/__delivest_redirect_probe?check=1"

    options =
      [redirect: false, retry: false, receive_timeout: 8_000] ++
        Application.get_env(:bastion, :req_options, [])

    case Req.get(url, options) do
      {:ok, %Req.Response{status: status} = response} when status in [301, 308] ->
        if Req.Response.get_header(response, "location") == [
             "https://#{new}/__delivest_redirect_probe?check=1"
           ],
           do: :ok,
           else: {:error, :wrong_redirect}

      _ ->
        {:error, :redirect_unverified}
    end
  end
end
