defmodule Bastion.Alerts.Thread do
  @moduledoc "The Telegram message of an alert that is not over yet, so its recovery answers it."

  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "alert_threads" do
    belongs_to :instance, Bastion.Instances.Instance
    field :key, :string
    field :message_id, :integer
    field :text, :string

    timestamps(type: :utc_datetime)
  end
end
