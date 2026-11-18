defmodule Bastion.Repo.Migrations.CreateIncidents do
  use Ecto.Migration

  def change do
    create table(:incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :instance_id, references(:instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :level, :string, null: false
      add :problems, {:array, :text}, null: false, default: []
      add :started_at, :utc_datetime, null: false
      add :ended_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:incidents, [:instance_id, :started_at])
  end
end
