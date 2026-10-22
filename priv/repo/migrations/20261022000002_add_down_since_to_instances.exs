defmodule Bastion.Repo.Migrations.AddDownSinceToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :down_since, :utc_datetime
    end
  end
end
