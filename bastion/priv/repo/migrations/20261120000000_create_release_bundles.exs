defmodule Bastion.Repo.Migrations.CreateReleaseBundles do
  use Ecto.Migration

  def change do
    create table(:release_bundles, primary_key: false) do
      add :version, :string, primary_key: true
      add :manifest, :map, null: false
      timestamps(type: :utc_datetime_usec)
    end
  end
end
