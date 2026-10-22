defmodule Bastion.Repo.Migrations.AddCrmDismissedToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :crm_dismissed, {:array, :string}, null: false, default: []
    end
  end
end
