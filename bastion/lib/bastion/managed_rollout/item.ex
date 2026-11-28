defmodule Bastion.ManagedRollout.Item do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "managed_rollout_items" do
    belongs_to :rollout, Bastion.ManagedRollout.Rollout
    belongs_to :instance, Bastion.Instances.Instance
    belongs_to :operation, Bastion.Nodes.Operation
    field :position, :integer
    field :status, :string, default: "pending"
    field :error, :string
    timestamps(type: :utc_datetime_usec)
  end
end
