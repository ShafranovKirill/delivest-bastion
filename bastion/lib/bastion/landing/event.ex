defmodule Bastion.Landing.Event do
  use Ecto.Schema
  import Ecto.Changeset

  schema "landing_events" do
    field :event_id, :string
    field :session_id, :string
    field :event, :string
    field :path, :string
    field :attribution, :map, default: %{}
    timestamps(type: :utc_datetime, updated_at: false)
  end

  def changeset(e, attrs),
    do:
      e
      |> cast(attrs, [:event_id, :session_id, :event, :path, :attribution])
      |> validate_required([:event_id, :session_id, :event])
end
