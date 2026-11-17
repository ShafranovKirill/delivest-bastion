defmodule Bastion.Repo.Migrations.AddClientDetailsAndPaymentReminders do
  use Ecto.Migration

  def change do
    alter table(:instances) do
      add :contact_phone, :string
      add :social_links, :text
      add :payment_due_on, :date
      add :admin_login, :string
      add :admin_password_encrypted, :text
    end

    create index(:instances, [:payment_due_on])

    create table(:payment_reminders) do
      add :instance_id, references(:instances, type: :binary_id, on_delete: :delete_all),
        null: false

      add :due_on, :date, null: false
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:payment_reminders, [:instance_id, :due_on])
  end
end
