defmodule Bastion.Repo.Migrations.RecordPlacementRestartGuards do
  use Ecto.Migration

  def change do
    alter table(:placements) do
      add :restart_guard, {:array, :map}, null: false, default: []
    end
  end
end
