defmodule Bastion.Domains.ZoneCredential do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  schema "dns_zone_credentials" do
    field :zone, :string
    field :provider, :string
    field :username, :string
    field :secret_ciphertext, :binary, redact: true
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(record, attrs) do
    record
    |> cast(attrs, [:zone, :provider, :username, :secret_ciphertext])
    |> validate_required([:zone, :provider, :username, :secret_ciphertext])
    |> unique_constraint([:zone, :provider])
  end
end
