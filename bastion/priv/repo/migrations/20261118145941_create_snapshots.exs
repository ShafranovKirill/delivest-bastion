defmodule Bastion.Repo.Migrations.CreateSnapshots do
  use Ecto.Migration

  def change do
    create table(:snapshots, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :instance_id, references(:instances, type: :binary_id, on_delete: :nilify_all)
      add :command_id, references(:commands, type: :binary_id, on_delete: :nilify_all)
      add :instance_name, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :key, :string, null: false
      add :size, :bigint
      add :error, :text
      add :requested_by, :string
      add :finished_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:snapshots, [:instance_id, :inserted_at])
    create unique_index(:snapshots, [:command_id])

    create unique_index(:snapshots, [:instance_id],
             where: "status = 'pending'",
             name: :snapshots_one_pending_per_instance
           )
  end
end
