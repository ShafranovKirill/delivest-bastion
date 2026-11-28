defmodule Bastion.Domains.Domain do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "domains" do
    field :hostname, :string
    field :zone, :string
    field :owner, :string
    field :dns_mode, :string
    field :dns_observation, :map, default: %{}
    field :https_observation, :map, default: %{}
    field :observed_at, :utc_datetime_usec
    has_many :bindings, Bastion.Domains.Binding
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:hostname, :zone, :owner, :dns_mode])
    |> update_change(:hostname, &normalize/1)
    |> validate_required([:hostname])
    |> validate_length(:hostname, max: 253)
    |> validate_format(:hostname, ~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/)
    |> validate_change(:hostname, fn :hostname, value ->
      labels = String.split(value, ".")

      if Enum.all?(
           labels,
           &(byte_size(&1) in 1..63 and not String.starts_with?(&1, "-") and
               not String.ends_with?(&1, "-"))
         ),
         do: [],
         else: [hostname: "invalid domain label"]
    end)
    |> unique_constraint(:hostname)
  end

  def normalize(hostname) when is_binary(hostname) do
    hostname
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
  end
end
