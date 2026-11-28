defmodule Bastion.Snapshots.Snapshot do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "snapshots" do
    belongs_to :instance, Bastion.Instances.Instance
    belongs_to :command, Bastion.Instances.Command
    belongs_to :node_operation, Bastion.Nodes.Operation
    field :kind, :string, default: "full"
    field :checksum, :string
    field :release_compatibility, :map, default: %{}
    field :integrity_checked_at, :utc_datetime_usec
    field :restore_checked_at, :utc_datetime_usec
    field :restore_checked_by, :string
    field :restore_evidence, :string
    field :drill_at, :utc_datetime_usec
    field :drill_status, :string
    field :drill_result, :map, default: %{}
    field :instance_name, :string
    field :status, :string, default: "pending"
    field :key, :string
    field :size, :integer
    field :error, :string
    field :requested_by, :string
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end
end
