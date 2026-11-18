defmodule Bastion.Metrics.Sample do
  use Ecto.Schema

  @foreign_key_type :binary_id

  schema "metric_samples" do
    belongs_to :instance, Bastion.Instances.Instance
    field :at, :utc_datetime
    field :cpu, :float
    field :memory, :float
    field :memory_used_kb, :integer
    field :memory_total_kb, :integer
    field :load, :float
    field :cpus, :integer
  end
end
