defmodule Bastion.Landing.LeadNotification do
  use Oban.Worker, queue: :checks, max_attempts: 3
  alias Bastion.{Repo, Telegram}
  alias Bastion.Landing.Lead

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"lead_id" => id}}) do
    case Repo.get(Lead, id) do
      nil ->
        :ok

      lead ->
        recipients = Bastion.Landing.settings().telegram_chat_ids
        recipients = if recipients == [], do: [Telegram.chat_id()], else: recipients

        if Telegram.token() && Enum.any?(recipients, & &1) do
          text =
            "Новая заявка с лендинга: #{lead.name} / #{lead.contact}" <>
              if(lead.intent, do: " / #{lead.intent}", else: "")

          results =
            Enum.reject(recipients, &is_nil/1)
            |> Enum.map(&Telegram.send_message(text, %{chat_id: &1}))

          case Enum.find(results, &match?({:error, _}, &1)) do
            nil -> :ok
            error -> error
          end
        else
          :ok
        end
    end
  end
end
