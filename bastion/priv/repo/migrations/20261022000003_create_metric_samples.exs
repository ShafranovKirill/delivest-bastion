defmodule Bastion.Repo.Migrations.CreateMetricSamples do
  use Ecto.Migration

  def change do
    create table(:metric_samples) do
      add :instance_id, references(:instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :at, :utc_datetime, null: false
      add :cpu, :float
      add :memory, :float
      add :memory_used_kb, :bigint
      add :memory_total_kb, :bigint
      add :load, :float
      add :cpus, :integer
    end

    create index(:metric_samples, [:instance_id, :at])
    create index(:metric_samples, [:at])
  end
end
