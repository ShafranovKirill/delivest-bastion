defmodule Bastion.Repo.Migrations.AddSiteAlertsToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :site_alerts, :map, null: false, default: %{}
    end
  end
end
