defmodule Bastion.Repo.Migrations.AddMaintenanceWindows do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :maintenance_until, :utc_datetime
    end

    create table(:maintenance_windows, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :instance_id, references(:instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :started_at, :utc_datetime, null: false
      add :scheduled_end_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:maintenance_windows, [:instance_id, :started_at])
  end
end
