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
    field :state, :string, default: "free"
    field :failure_reason, :string
    field :next_step, :string
    has_many :bindings, Bastion.Domains.Binding
    timestamps(type: :utc_datetime_usec)
  end

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, [:hostname, :zone, :owner, :dns_mode, :state, :failure_reason, :next_step])
    |> update_change(:hostname, &normalize/1)
    |> update_change(:zone, &normalize/1)
    |> validate_required([:hostname])
    |> validate_length(:hostname, max: 253)
    |> validate_format(:hostname, ~r/\A[a-z0-9](?:[a-z0-9.-]*[a-z0-9])?\z/)
    |> validate_change(:hostname, fn :hostname, value ->
      labels = String.split(value, ".")

      if length(labels) >= 2 and
           Enum.all?(
             labels,
             &(byte_size(&1) in 1..63 and not String.starts_with?(&1, "-") and
                 not String.ends_with?(&1, "-"))
           ),
         do: [],
         else: [hostname: "invalid domain label"]
    end)
    |> validate_zone()
    |> unique_constraint(:hostname)
    |> validate_inclusion(:dns_mode, ~w(regru external manual))
    |> validate_inclusion(
      :state,
      ~w(free reserved waiting_dns preparing_https checking connected error)
    )
  end

  def normalize(hostname) when is_binary(hostname) do
    hostname
    |> String.trim()
    |> String.trim_trailing(".")
    |> String.downcase()
    |> then(fn name ->
      try do
        case :idna.encode(String.to_charlist(name)) do
          {:ok, encoded} -> to_string(encoded)
          encoded when is_list(encoded) -> to_string(encoded)
          _ -> name
        end
      rescue
        _ -> name
      catch
        _, _ -> name
      end
    end)
  end

  defp validate_zone(changeset) do
    if get_field(changeset, :dns_mode) == "regru" do
      changeset = validate_required(changeset, [:zone])
      zone = get_field(changeset, :zone)
      host = get_field(changeset, :hostname)

      if is_binary(zone) and is_binary(host) and
           (host == zone or String.ends_with?(host, "." <> zone)) and
           length(String.split(zone, ".")) >= 2 do
        changeset
      else
        add_error(changeset, :zone, "must contain this hostname")
      end
    else
      changeset
    end
  end
end
