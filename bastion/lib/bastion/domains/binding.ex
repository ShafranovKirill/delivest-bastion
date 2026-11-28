defmodule Bastion.Domains.Binding do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "domain_bindings" do
    belongs_to :domain, Bastion.Domains.Domain
    belongs_to :instance, Bastion.Instances.Instance
    field :purpose, :string
    field :primary, :boolean, default: false
    field :routing, :string, default: "serve"
    field :state, :string, default: "reserved"
    field :verification_token_hash, :binary, redact: true
    field :verification_name, :string
    field :expected_records, :map, default: %{}
    field :observed_records, :map, default: %{}
    field :owned_records, :map, default: %{}
    field :active_operation_id, :binary_id
    field :certificate_expires_at, :utc_datetime_usec
    field :last_checked_at, :utc_datetime_usec
    field :failure_reason, :string
    field :next_step, :string
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:purpose, :primary, :routing, :state])
    |> validate_required([:purpose, :routing, :state])
    |> validate_inclusion(:purpose, ~w(site admin api media))
    |> validate_inclusion(
      :state,
      ~w(reserved waiting_dns preparing_https checking connected error released)
    )
    |> foreign_key_constraint(:instance_id)
    |> foreign_key_constraint(:domain_id)
    |> unique_constraint([:instance_id, :purpose], name: :domain_bindings_one_primary_live)
  end
end
