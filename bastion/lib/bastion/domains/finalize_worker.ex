defmodule Bastion.Domains.FinalizeWorker do
  use Oban.Worker, queue: :default, max_attempts: 5

  alias Bastion.{Domains, Repo}
  alias Bastion.Nodes.Operation

  @impl true
  def perform(%Oban.Job{args: %{"operation_id" => id}}) do
    case Repo.get(Operation, id) do
      %Operation{} = operation ->
        case Domains.complete_operation(operation) do
          {:error, reason} when reason in [:https_unverified, :release_unconfirmed] ->
            operation
            |> Ecto.Changeset.change(
              status: "error",
              result: Map.put(operation.result, "reason", to_string(reason)),
              finished_at: DateTime.utc_now()
            )
            |> Repo.update!()

            :ok

          {:error, reason} ->
            {:error, reason}

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end
end
