defmodule Bastion.Repo.Migrations.AddStoppedAtToInstances do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :stopped_at, :utc_datetime
    end
  end
end
