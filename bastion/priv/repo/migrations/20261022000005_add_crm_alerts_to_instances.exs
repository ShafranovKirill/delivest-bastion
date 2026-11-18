defmodule Bastion.Repo.Migrations.AddCrmAlertsToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :crm_alerts, :map, null: false, default: %{}
    end
  end
end
