defmodule Bastion.ManagedRollout.Rollout do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "managed_rollouts" do
    field :version, :string
    field :url, :string
    field :sha256, :string
    field :status, :string, default: "running"
    field :requested_by, :string
    field :paused_reason, :string
    has_many :items, Bastion.ManagedRollout.Item
    timestamps(type: :utc_datetime_usec)
  end
end
