defmodule Bastion.Repo.Migrations.CreateInstances do
  use Ecto.Migration

  def change do
    create table(:instances, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :name, :string, null: false
      add :hosts, :map, null: false, default: %{}
      add :agent_version, :string
      add :actions, {:array, :string}, null: false, default: []
      add :status, :map
      add :last_seen_at, :utc_datetime
      add :external, :map, null: false, default: %{}
      add :checked_at, :utc_datetime
      add :health, :string, null: false, default: "unknown"
      timestamps(type: :utc_datetime)
    end

    create table(:commands, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :instance_id, references(:instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :action, :string, null: false
      add :args, :map, null: false, default: %{}
      add :status, :string, null: false
      add :output, :text
      add :requested_by, :string
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:commands, [:instance_id, :inserted_at])
  end
end
