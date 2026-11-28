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
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(binding, attrs) do
    binding
    |> cast(attrs, [:purpose, :primary, :routing, :state])
    |> validate_required([:purpose, :routing, :state])
    |> validate_inclusion(:purpose, ~w(site admin api media))
    |> validate_inclusion(:state, ~w(reserved active released))
  end
end
