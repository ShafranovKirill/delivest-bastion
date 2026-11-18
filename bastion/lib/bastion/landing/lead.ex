defmodule Bastion.Landing.Lead do
  use Ecto.Schema
  import Ecto.Changeset

  schema "landing_leads" do
    field :request_id, :string
    field :session_id, :string
    field :name, :string
    field :contact, :string
    field :intent, :string
    field :status, :string, default: "new"
    field :attribution, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def changeset(l, attrs),
    do:
      l
      |> cast(attrs, [:request_id, :session_id, :name, :contact, :intent, :status, :attribution])
      |> validate_required([:request_id, :session_id, :contact])
end
