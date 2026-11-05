defmodule Bastion.Maintenance.Window do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "maintenance_windows" do
    belongs_to :instance, Bastion.Instances.Instance
    field :started_at, :utc_datetime
    field :scheduled_end_at, :utc_datetime
    field :ended_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end
end
