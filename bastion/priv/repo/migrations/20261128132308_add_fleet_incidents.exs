defmodule Bastion.Repo.Migrations.AddFleetIncidents do
  use Ecto.Migration

  def change do
    create table(:fleet_incidents, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :node_id, references(:nodes, type: :binary_id, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :affected, :map, null: false
      add :started_at, :utc_datetime_usec, null: false
      add :ended_at, :utc_datetime_usec
    end

    create unique_index(:fleet_incidents, [:node_id], where: "ended_at IS NULL")
  end
end
