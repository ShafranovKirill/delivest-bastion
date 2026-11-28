defmodule Bastion.Nodes.MetricSample do
  use Ecto.Schema

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "node_metric_samples" do
    belongs_to :node, Bastion.Nodes.Node
    field :sample_id, :string
    field :sampled_at, :utc_datetime_usec
    field :received_at, :utc_datetime_usec
    field :metrics, :map, default: %{}
  end
end
