defmodule Bastion.Nodes.Placement do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "placements" do
    belongs_to :instance, Bastion.Instances.Instance
    belongs_to :node, Bastion.Nodes.Node
    field :revision, :integer
    field :project_name, :string
    field :gateway_port, :integer
    field :state, :string, default: "reserved"
    field :observed_state, :string
    field :observed_release, :string
    field :observed_at, :utc_datetime_usec
    field :restart_guard, {:array, :map}, default: []
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(placement, attrs) do
    placement
    |> cast(attrs, [:revision, :project_name, :gateway_port, :state])
    |> validate_required([:revision, :project_name, :gateway_port, :state])
    |> validate_number(:revision, greater_than: 0)
    |> validate_number(:gateway_port, greater_than: 1023, less_than: 65_536)
    |> validate_inclusion(:state, ~w(reserved active retired))
    |> unique_constraint([:instance_id, :revision])
    |> unique_constraint([:node_id, :project_name])
    |> unique_constraint([:node_id, :gateway_port])
  end
end
