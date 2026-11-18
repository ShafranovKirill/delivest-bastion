defmodule Bastion.Instances.Command do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(sent running ok error)

  schema "commands" do
    belongs_to :instance, Bastion.Instances.Instance
    field :action, :string
    field :args, :map, default: %{}
    field :status, :string, default: "sent"
    field :output, :string
    field :requested_by, :string
    field :started_at, :utc_datetime
    field :finished_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses
end
