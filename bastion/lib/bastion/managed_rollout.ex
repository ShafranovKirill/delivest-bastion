defmodule Bastion.ManagedRollout do
  @moduledoc "Persistent sequential updates of a fixed set of managed installations."

  import Ecto.Query

  alias Bastion.{ManagedUpdates, Nodes, Repo}
  alias Bastion.Instances.Instance
  alias Bastion.ManagedRollout.{Item, Rollout, Worker}
  alias Bastion.Nodes.Placement

  def latest do
    Repo.one(
      from r in Rollout,
        order_by: [desc: r.inserted_at],
        limit: 1,
        preload: [items: [:instance, :operation]]
    )
  end

  def get(id), do: Repo.get(Rollout, id) |> Repo.preload(items: [:instance, :operation])

  def start(ids, canary_id, requested_by, release \\ nil)

  def start(ids, canary_id, requested_by, release)
      when is_list(ids) and is_binary(requested_by) do
    with {:ok, release} <- ManagedUpdates.resolve(release),
         {:ok, ids} <- select_candidates(ids, canary_id, release) do
      result =
        Repo.transaction(fn ->
          if Repo.exists?(from r in Rollout, where: r.status == "running"),
            do: Repo.rollback(:already_running)

          rollout =
            %Rollout{
              version: release.version,
              url: release.url,
              sha256: release.sha256,
              requested_by: requested_by
            }
            |> Ecto.Changeset.change()
            |> Ecto.Changeset.unique_constraint(:status, name: :managed_rollouts_one_running)
            |> Repo.insert()
            |> case do
              {:ok, rollout} -> rollout
              {:error, _} -> Repo.rollback(:already_running)
            end

          ids
          |> Enum.with_index()
          |> Enum.each(fn {id, position} ->
            Repo.insert!(%Item{rollout_id: rollout.id, instance_id: id, position: position})
          end)

          Oban.insert!(Worker.new(%{"rollout_id" => rollout.id}))
          rollout
        end)

      case result do
        {:ok, rollout} -> {:ok, get(rollout.id)}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  def start(_, _, _, _), do: {:error, :invalid_selection}

  def resume(id, requested_by) when is_binary(requested_by) do
    Repo.transaction(fn ->
      rollout =
        Repo.one(from r in Rollout, where: r.id == ^id, lock: "FOR UPDATE") ||
          Repo.rollback(:not_found)

      if rollout.status != "paused", do: Repo.rollback(:not_paused)

      if Repo.exists?(from r in Rollout, where: r.status == "running"),
        do: Repo.rollback(:already_running)

      rollout
      |> Ecto.Changeset.change(status: "running", paused_reason: nil, requested_by: requested_by)
      |> Repo.update!()

      # A failed item is retried. A command whose result is unknown keeps its ID.
      Repo.update_all(
        from(i in Item, where: i.rollout_id == ^id and i.status == "error"),
        set: [status: "pending", operation_id: nil, error: nil]
      )

      Oban.insert!(Worker.new(%{"rollout_id" => id}))
    end)
  end

  def advance(id) do
    result =
      Repo.transaction(fn ->
        rollout = Repo.one(from r in Rollout, where: r.id == ^id, lock: "FOR UPDATE")

        if is_nil(rollout) or rollout.status != "running",
          do: :inactive,
          else: advance_locked(rollout)
      end)

    case result do
      {:ok, {:dispatch, operation}} ->
        Nodes.dispatch_operation(operation)
        :ok

      {:ok, _} ->
        :ok

      {:error, {:dispatch_failed, reason}} ->
        pause_dispatch_failure(id, reason)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp advance_locked(rollout) do
    item =
      Repo.one(
        from i in Item,
          where: i.rollout_id == ^rollout.id and i.status in ["pending", "running", "unknown"],
          order_by: [asc: i.position],
          limit: 1,
          lock: "FOR UPDATE"
      )

    case item do
      nil ->
        rollout |> Ecto.Changeset.change(status: "done") |> Repo.update!()
        :done

      %Item{status: "pending"} ->
        dispatch_item(rollout, item)

      %Item{} ->
        reconcile_item(rollout, item)
    end
  end

  defp dispatch_item(rollout, item) do
    release = %{version: rollout.version, url: rollout.url, sha256: rollout.sha256}

    case queue_item(item, rollout, release) do
      {:ok, operation} ->
        item
        |> Ecto.Changeset.change(status: "running", operation_id: operation.id)
        |> Repo.update!()

        {:dispatch, operation}

      {:error, reason} ->
        Repo.rollback({:dispatch_failed, reason})
    end
  end

  defp queue_item(item, rollout, release) do
    Repo.transaction(fn ->
      ManagedUpdates.queue_pinned!(item.instance_id, rollout.requested_by, release)
    end)
  end

  defp pause_dispatch_failure(id, reason) do
    Repo.transaction(fn ->
      rollout = Repo.one!(from r in Rollout, where: r.id == ^id, lock: "FOR UPDATE")

      if rollout.status == "running" do
        item =
          Repo.one!(
            from i in Item,
              where: i.rollout_id == ^id and i.status == "pending",
              order_by: [asc: i.position],
              limit: 1,
              lock: "FOR UPDATE"
          )

        fail_item(rollout, item, inspect(reason))
      end
    end)

    :ok
  end

  defp reconcile_item(rollout, item) do
    operation = Repo.get!(Bastion.Nodes.Operation, item.operation_id)

    case operation.status do
      "ok" ->
        item |> Ecto.Changeset.change(status: "ok") |> Repo.update!()
        advance_locked(rollout)

      "error" ->
        fail_item(rollout, item, inspect(operation.result))

      "unknown" ->
        item |> Ecto.Changeset.change(status: "unknown") |> Repo.update!()
        pause(rollout, "Результат команды неизвестен, требуется сверка с нодой")

      _ ->
        :waiting
    end
  end

  defp fail_item(rollout, item, reason) do
    item |> Ecto.Changeset.change(status: "error", error: reason) |> Repo.update!()
    pause(rollout, reason)
  end

  defp pause(rollout, reason) do
    rollout
    |> Ecto.Changeset.change(status: "paused", paused_reason: reason)
    |> Repo.update!()

    :paused
  end

  defp select_candidates(ids, canary_id, release) do
    all? = ids == []
    ids = if all?, do: Map.keys(Nodes.active_placements()), else: Enum.uniq(ids)
    ids = if all?, do: Enum.reject(ids, &installed?(&1, release.version)), else: ids

    valid =
      ids != [] and canary_id in ids and
        Enum.all?(ids, fn id ->
          case Nodes.placement_for(id) do
            %Placement{observed_state: "running", observed_release: version, node: node}
            when is_binary(version) ->
              match?(%Instance{transport: "node"}, Repo.get(Instance, id)) and
                not node.maintenance and Bastion.Releases.newer?(release.version, version)

            _ ->
              false
          end
        end)

    if valid,
      do: {:ok, [canary_id | Enum.sort(ids -- [canary_id])]},
      else: {:error, :invalid_selection}
  end

  defp installed?(id, version) do
    case Nodes.placement_for(id) do
      %Placement{observed_release: ^version} -> true
      _ -> false
    end
  end
end
