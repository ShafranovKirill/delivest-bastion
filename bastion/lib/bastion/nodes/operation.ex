defmodule Bastion.Nodes.Operation do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  @statuses ~w(pending running waiting_external ok error unknown)

  schema "node_operations" do
    belongs_to :node, Bastion.Nodes.Node
    belongs_to :instance, Bastion.Instances.Instance
    belongs_to :placement, Bastion.Nodes.Placement
    field :placement_revision, :integer
    field :action, :string
    field :args, :map, default: %{}
    field :status, :string, default: "pending"
    field :progress, :map, default: %{}
    field :result, :map, default: %{}
    field :requested_by, :string
    field :acknowledged_at, :utc_datetime_usec
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(operation, attrs) do
    operation
    |> cast(attrs, [:action, :args, :status, :requested_by])
    |> validate_required([:action, :status])
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:instance_id, name: :node_operations_one_unresolved_per_instance)
  end
end
