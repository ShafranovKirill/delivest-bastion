defmodule Bastion.Repo.Migrations.AddLoadAlertsToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :load_alerts, :map, null: false, default: %{}
    end
  end
end
