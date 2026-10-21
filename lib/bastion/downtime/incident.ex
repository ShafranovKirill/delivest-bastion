defmodule Bastion.Downtime.Incident do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "incidents" do
    belongs_to :instance, Bastion.Instances.Instance
    field :level, :string
    field :problems, {:array, :string}, default: []
    field :started_at, :utc_datetime
    field :ended_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
