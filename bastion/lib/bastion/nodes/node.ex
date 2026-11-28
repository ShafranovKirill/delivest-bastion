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
    field :public_ipv4, :string
    field :public_ipv6, :string
    field :ssh_host, :string
    field :ssh_port, :integer
    field :ssh_login, :string
    field :ssh_fingerprint, :string
    field :install_status, :string, default: "not_started"
    field :install_progress, :map, default: %{}
    field :install_error, :string
    field :infrastructure, :map, default: %{}
    has_many :placements, Bastion.Nodes.Placement
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :name,
      :maintenance,
      :public_ipv4,
      :public_ipv6,
      :ssh_host,
      :ssh_port,
      :ssh_login,
      :ssh_fingerprint
    ])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
    |> unique_constraint([:ssh_host, :ssh_port], name: :nodes_one_ssh_target)
  end
end
