defmodule Bastion.Repo.Migrations.AddManagedRecoveryDrills do
  use Ecto.Migration

  def change do
    alter table(:snapshots) do
      add :drill_at, :utc_datetime_usec
      add :drill_status, :string
      add :drill_result, :map, default: %{}, null: false
    end
  end
end
