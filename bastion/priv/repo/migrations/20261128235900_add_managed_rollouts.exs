defmodule Bastion.Repo.Migrations.AddManagedRollouts do
  use Ecto.Migration

  def change do
    alter table(:node_operations) do
      add :request_key, :string
    end

    create unique_index(:node_operations, [:request_key], where: "request_key IS NOT NULL")

    create table(:managed_rollouts, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :version, :string, null: false
      add :url, :string, null: false
      add :sha256, :string, null: false
      add :status, :string, null: false, default: "running"
      add :requested_by, :string, null: false
      add :paused_reason, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_rollouts, [:status],
             where: "status = 'running'",
             name: :managed_rollouts_one_running
           )

    create table(:managed_rollout_items, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :rollout_id, references(:managed_rollouts, type: :binary_id, on_delete: :restrict),
        null: false

      add :instance_id, references(:instances, type: :binary_id, on_delete: :restrict),
        null: false

      add :position, :integer, null: false
      add :status, :string, null: false, default: "pending"
      add :operation_id, references(:node_operations, type: :binary_id, on_delete: :restrict)
      add :error, :string
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:managed_rollout_items, [:rollout_id, :instance_id])
    create unique_index(:managed_rollout_items, [:rollout_id, :position])

    create unique_index(:managed_rollout_items, [:operation_id],
             where: "operation_id IS NOT NULL"
           )
  end
end
