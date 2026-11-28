defmodule Bastion.Fleet.Incident do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fleet_incidents" do
    belongs_to :node, Bastion.Nodes.Node
    field :kind, :string
    field :affected, :map
    field :started_at, :utc_datetime_usec
    field :ended_at, :utc_datetime_usec
  end
end
