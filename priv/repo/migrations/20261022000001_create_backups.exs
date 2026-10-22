defmodule Bastion.Repo.Migrations.CreateBackups do
  use Ecto.Migration

  def change do
    create table(:backups, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :instance_id, references(:instances, type: :binary_id, on_delete: :nilify_all)
      add :command_id, references(:commands, type: :binary_id, on_delete: :nilify_all)
      add :instance_name, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :key, :string, null: false
      add :size, :bigint
      add :error, :text
      add :requested_by, :string
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:backups, [:instance_id, :inserted_at])
    create index(:backups, [:command_id])
  end
end
