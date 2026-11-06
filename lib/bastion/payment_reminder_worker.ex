defmodule Bastion.PaymentReminderWorker do
  use Oban.Worker, queue: :checks, max_attempts: 1
  import Ecto.Query
  alias Bastion.{Repo, Telegram, PaymentReminder}
  alias Bastion.Instances.Instance

  # Moscow is UTC+3; no external timezone database is required.
  def today, do: DateTime.utc_now() |> DateTime.add(3 * 3600) |> DateTime.to_date()

  @impl Oban.Worker
  def perform(_job), do: deliver_due(DateTime.utc_now())

  def deliver_due(now) do
    local = DateTime.add(now, 3 * 3600)

    if local.hour >= 9 and Telegram.configured?() do
      due_on = DateTime.to_date(local)

      results =
        Repo.all(from i in Instance, where: i.payment_due_on == ^due_on, select: i.id)
        |> Enum.map(&deliver(&1, due_on))

      case Enum.find(results, &match?({:error, _}, &1)) do
        nil -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      :ok
    end
  end

  defp deliver(id, due_on) do
    Repo.transaction(fn ->
      instance = Repo.one(from i in Instance, where: i.id == ^id, lock: "FOR UPDATE")

      sent? =
        Repo.exists?(
          from r in PaymentReminder, where: r.instance_id == ^id and r.due_on == ^due_on
        )

      if instance && instance.payment_due_on == due_on && not sent? do
        case Telegram.send_message(
               "Франшиза «#{instance.name}» должна сегодня оплатить подписку."
             ) do
          {:ok, _} -> Repo.insert!(%PaymentReminder{instance_id: id, due_on: due_on})
          {:error, reason} -> Repo.rollback(reason)
        end
      end
    end)
  end
end
