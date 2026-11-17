defmodule Bastion.Telegram.UpdateWorker do
  @moduledoc "Serial, durable delivery of Telegram updates and command notifications."
  use Oban.Worker,
    queue: :telegram,
    max_attempts: 1,
    unique: [
      period: 86_400,
      fields: [:worker, :args],
      keys: [:kind, :id, :status],
      states: [:available, :scheduled, :executing, :retryable, :completed, :discarded]
    ]

  alias Bastion.Repo
  alias Bastion.Telegram.Bot

  def enqueue_update(%{"update_id" => id} = update) when is_integer(id) do
    %{kind: "update", id: id, update: update} |> new() |> Oban.insert() |> persisted()
  end

  def enqueue_command(command) do
    %{kind: "command", id: command.id, status: command.status}
    |> new()
    |> Oban.insert()
    |> persisted()
  end

  # Oban's Basic engine may report a lock conflict without inserting a row.
  # Telegram must retry that update instead of receiving an acknowledgement.
  defp persisted({:ok, %Oban.Job{id: nil}}), do: {:error, :enqueue_conflict}
  defp persisted(result), do: result

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"kind" => "update", "update" => update}}) do
    normalize(Bot.handle_update(update))
  end

  def perform(%Oban.Job{args: %{"kind" => "command", "id" => id, "status" => status}}) do
    case Repo.get(Bastion.Instances.Command, id) do
      %{status: ^status} = command -> normalize(Bot.command_updated(command))
      _ -> :ok
    end
  end

  defp normalize({:error, _} = error), do: error
  defp normalize(_), do: :ok
end
