defmodule Bastion.Backups.Backup do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "backups" do
    belongs_to :instance, Bastion.Instances.Instance
    belongs_to :command, Bastion.Instances.Command
    field :instance_name, :string
    field :status, :string, default: "pending"
    field :key, :string
    field :size, :integer
    field :error, :string
    field :requested_by, :string
    field :finished_at, :utc_datetime
    field :verify_status, :string
    field :verify_error, :string
    field :verified_at, :utc_datetime
    field :offsite_at, :utc_datetime
    field :offsite_error, :string

    timestamps(type: :utc_datetime)
  end
end
