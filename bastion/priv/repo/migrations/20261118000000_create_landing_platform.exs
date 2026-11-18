defmodule Bastion.Repo.Migrations.CreateLandingPlatform do
  use Ecto.Migration

  def change do
    create table(:landing_settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :canonical_url, :string, null: false, default: "https://delivest.ru"
      add :tracking_enabled, :boolean, null: false, default: true
      add :metrika_enabled, :boolean, null: false, default: false
      add :metrika_counter_id, :string
      add :goal_lead_open, :string, null: false, default: "lead_open"
      add :goal_lead_success, :string, null: false, default: "lead_success"
      add :goal_contact_telegram, :string, null: false, default: "contact_telegram"
      add :goal_contact_vk, :string, null: false, default: "contact_vk"
      add :goal_contact_phone, :string, null: false, default: "contact_phone"
      add :yandex_token, :text
      add :direct_login, :string
      add :direct_campaign_ids, {:array, :integer}, null: false, default: []
      add :telegram_chat_ids, {:array, :string}, null: false, default: []
      add :metrika_visits, :integer
      add :direct_spend_micros, :bigint
      add :direct_clicks, :integer
      add :sync_from, :date
      add :sync_to, :date
      add :sync_at, :utc_datetime
      add :sync_error, :text
      timestamps(type: :utc_datetime)
    end

    create constraint(:landing_settings, :landing_settings_singleton, check: "id = 1")

    create table(:landing_events) do
      add :event_id, :string, null: false
      add :session_id, :string, null: false
      add :event, :string, null: false
      add :path, :string
      add :attribution, :map, null: false, default: %{}
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create unique_index(:landing_events, [:event_id])
    create index(:landing_events, [:inserted_at])

    create table(:landing_leads) do
      add :request_id, :string, null: false
      add :session_id, :string, null: false
      add :name, :string
      add :contact, :string, null: false
      add :intent, :string
      add :status, :string, null: false, default: "new"
      add :attribution, :map, null: false, default: %{}
      timestamps(type: :utc_datetime)
    end

    create unique_index(:landing_leads, [:request_id])
    create index(:landing_leads, [:inserted_at])
  end
end
