defmodule Bastion.Instances.Instance do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  schema "instances" do
    field :contact_phone, :string
    field :social_links, :string
    field :payment_due_on, :date
    field :admin_login, :string
    field :admin_password, :string, virtual: true, redact: true
    field :admin_password_encrypted, :string, redact: true
    field :name, :string
    field :hosts, :map, default: %{}
    field :agent_version, :string
    field :actions, {:array, :string}, default: []
    field :status, :map
    field :last_seen_at, :utc_datetime
    field :external, :map, default: %{}
    field :checked_at, :utc_datetime
    field :health, :string, default: "unknown"
    field :stopped_at, :utc_datetime
    field :maintenance_until, :utc_datetime
    field :down_since, :utc_datetime
    field :load_alerts, :map, default: %{}
    field :crm_alerts, :map, default: %{}
    field :crm_dismissed, {:array, :string}, default: []
    field :site_alerts, :map, default: %{}
    field :muted_until, :utc_datetime
    field :online, :boolean, virtual: true, default: false

    has_many :commands, Bastion.Instances.Command
    has_many :incidents, Bastion.Downtime.Incident
    has_many :maintenance_windows, Bastion.Maintenance.Window

    timestamps(type: :utc_datetime)
  end

  def client_changeset(instance, attrs) do
    instance
    |> cast(attrs, [:contact_phone, :social_links, :payment_due_on, :admin_login, :admin_password])
    |> validate_length(:contact_phone, max: 80)
    |> validate_length(:social_links, max: 2000)
    |> validate_length(:admin_login, max: 255)
    |> validate_length(:admin_password, max: 1024)
    |> validate_change(:social_links, fn :social_links, links ->
      if Enum.all?(String.split(links, ~r/\s+/, trim: true), &Bastion.Credentials.safe_link?/1),
        do: [],
        else: [social_links: "Укажите ссылки https:// или http://, каждую с новой строки"]
    end)
  end

  def register_changeset(instance, attrs) do
    instance
    |> cast(attrs, [:name, :hosts, :agent_version, :actions])
    |> validate_required([:name])
    |> validate_length(:name, max: 255)
  end
end
