defmodule Bastion.Repo.Migrations.AddAlertThreadsAndMute do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :muted_until, :utc_datetime
    end

    create table(:alert_threads, primary_key: false) do
      add :id, :binary_id, primary_key: true

      add :instance_id, references(:instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :key, :string, null: false
      add :message_id, :bigint, null: false
      add :text, :text, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:alert_threads, [:instance_id, :key])
  end
end
