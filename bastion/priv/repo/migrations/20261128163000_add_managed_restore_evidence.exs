defmodule Bastion.Repo.Migrations.AddManagedRestoreEvidence do
  use Ecto.Migration

  def change do
    alter table(:snapshots) do
      add :restore_checked_by, :string
      add :restore_evidence, :text
    end
  end
end
