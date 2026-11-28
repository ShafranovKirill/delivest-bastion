defmodule Bastion.Nodes.Node do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "nodes" do
    field :name, :string
    field :registration_token_hash, :binary, redact: true
    field :credential_hash, :binary, redact: true
    field :credential_revision, :integer, default: 0
    field :credential_revoked_at, :utc_datetime_usec
    field :maintenance, :boolean, default: false
    field :version, :string
    field :last_seen_at, :utc_datetime_usec
    field :sampled_at, :utc_datetime_usec
    field :metrics, :map, default: %{}
    has_many :placements, Bastion.Nodes.Placement
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [:name, :maintenance])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
  end
end
