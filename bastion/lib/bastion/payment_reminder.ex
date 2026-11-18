defmodule Bastion.PaymentReminder do
  use Ecto.Schema

  schema "payment_reminders" do
    field :instance_id, :binary_id
    field :due_on, :date
    timestamps(type: :utc_datetime, updated_at: false)
  end
end
