defmodule Bastion.Repo.Migrations.AddInstanceCapabilities do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :capabilities, {:array, :string}, null: false, default: []
    end
  end
end
