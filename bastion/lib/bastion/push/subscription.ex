defmodule Bastion.Push.Subscription do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "push_subscriptions" do
    field :endpoint, :string
    field :p256dh, :string
    field :auth, :string
    field :user_agent, :string
    field :admin, :string

    timestamps(type: :utc_datetime)
  end

  def changeset(subscription, attrs) do
    subscription
    |> cast(attrs, [:endpoint, :p256dh, :auth, :user_agent])
    |> validate_required([:endpoint, :p256dh, :auth])
    |> validate_format(:endpoint, ~r/^https:\/\//)
    |> validate_length(:user_agent, max: 500)
  end
end
