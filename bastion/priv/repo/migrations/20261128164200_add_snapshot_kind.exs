defmodule Bastion.Repo.Migrations.AddSnapshotKind do
  use Ecto.Migration

  def change do
    alter table(:snapshots) do
      add :kind, :string, default: "full", null: false
    end

    create constraint(:snapshots, :snapshots_known_kind, check: "kind IN ('full', 'postgres')")
  end
end
