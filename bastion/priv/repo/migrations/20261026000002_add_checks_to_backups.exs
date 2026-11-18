defmodule Bastion.Repo.Migrations.AddChecksToBackups do
  use Ecto.Migration

  def change do
    alter table(:backups) do
      add :verify_status, :string
      add :verify_error, :text
      add :verified_at, :utc_datetime
      add :offsite_at, :utc_datetime
      add :offsite_error, :text
    end
  end
end
