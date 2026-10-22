defmodule Bastion.Instances.Instance do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "instances" do
    field :name, :string
    field :hosts, :map, default: %{}
    field :agent_version, :string
    field :actions, {:array, :string}, default: []
    field :status, :map
    field :last_seen_at, :utc_datetime
    field :external, :map, default: %{}
    field :checked_at, :utc_datetime
    field :health, :string, default: "unknown"
    field :stopped_at, :utc_datetime
    field :down_since, :utc_datetime
    field :online, :boolean, virtual: true, default: false

    has_many :commands, Bastion.Instances.Command
    has_many :incidents, Bastion.Downtime.Incident

    timestamps(type: :utc_datetime)
  end

  def register_changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :hosts, :agent_version, :actions])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
  end
end
