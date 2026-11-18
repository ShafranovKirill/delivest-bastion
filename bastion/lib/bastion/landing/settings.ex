defmodule Bastion.Landing.Settings do
  use Ecto.Schema
  import Ecto.Changeset
  @primary_key {:id, :integer, autogenerate: false}
  schema "landing_settings" do
    field :canonical_url, :string, default: "https://delivest.ru"
    field :tracking_enabled, :boolean, default: true
    field :metrika_enabled, :boolean, default: false
    field :metrika_counter_id, :string
    field :goal_lead_open, :string, default: "lead_open"
    field :goal_lead_success, :string, default: "lead_success"
    field :goal_contact_telegram, :string, default: "contact_telegram"
    field :goal_contact_vk, :string, default: "contact_vk"
    field :goal_contact_phone, :string, default: "contact_phone"
    field :yandex_token, :string, redact: true
    field :direct_login, :string
    field :direct_campaign_ids, {:array, :integer}, default: []
    field :telegram_chat_ids, {:array, :string}, default: []
    field :metrika_visits, :integer
    field :direct_spend_micros, :integer
    field :direct_clicks, :integer
    field :sync_from, :date
    field :sync_to, :date
    field :sync_at, :utc_datetime
    field :sync_error, :string
    timestamps(type: :utc_datetime)
  end

  def changeset(s, attrs) do
    s
    |> cast(
      attrs,
      ~w(canonical_url tracking_enabled metrika_enabled metrika_counter_id goal_lead_open goal_lead_success goal_contact_telegram goal_contact_vk goal_contact_phone yandex_token direct_login direct_campaign_ids telegram_chat_ids metrika_visits direct_spend_micros direct_clicks sync_from sync_to sync_at sync_error)a
    )
    |> validate_required([
      :canonical_url,
      :goal_lead_open,
      :goal_lead_success,
      :goal_contact_telegram,
      :goal_contact_vk,
      :goal_contact_phone
    ])
    |> validate_length(:canonical_url, max: 250)
    |> validate_change(:canonical_url, fn _, value ->
      uri = URI.parse(value)

      if uri.scheme == "https" and is_binary(uri.host) and uri.host != "",
        do: [],
        else: [canonical_url: "must be an HTTPS URL"]
    end)
    |> validate_format(:metrika_counter_id, ~r/^\d+$/)
    |> validate_length(:yandex_token, max: 2000)
    |> validate_length(:direct_login, max: 100)
    |> validate_change(:direct_campaign_ids, fn _, ids ->
      if length(ids) <= 100 and Enum.all?(ids, &(&1 > 0)),
        do: [],
        else: [direct_campaign_ids: "invalid campaigns"]
    end)
    |> validate_change(:telegram_chat_ids, fn _, ids ->
      if length(ids) <= 20 and Enum.all?(ids, &Regex.match?(~r/^-?\d+$/, &1)),
        do: [],
        else: [telegram_chat_ids: "invalid recipients"]
    end)
    |> then(fn cs ->
      if get_field(cs, :metrika_enabled) and blank?(get_field(cs, :metrika_counter_id)),
        do: add_error(cs, :metrika_counter_id, "counter required"),
        else: cs
    end)
  end

  defp blank?(s), do: is_nil(s) or s == ""
end
