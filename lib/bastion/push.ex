defmodule Bastion.Push do
  @moduledoc """
  Notifications on the devices where the admin turned them on in the installed bastion.
  Every alert that goes to Telegram goes here too.
  """

  import Ecto.Query, warn: false

  require Logger

  alias Bastion.Push.{Subscription, WebPush, Worker}
  alias Bastion.Repo

  # Derived from SECRET_KEY_BASE, so the key stays the same without extra settings.
  def keys, do: WebPush.keys_from_seed(BastionWeb.Endpoint.config(:secret_key_base))

  def public_key, do: keys() |> elem(0) |> WebPush.encode64()

  def subscribe(attrs, admin) do
    %Subscription{admin: admin}
    |> Subscription.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace, [:p256dh, :auth, :user_agent, :admin, :updated_at]},
      conflict_target: :endpoint
    )
  end

  def unsubscribe(endpoint) when is_binary(endpoint) do
    Repo.delete_all(from(s in Subscription, where: s.endpoint == ^endpoint))
    :ok
  end

  def any?, do: Repo.exists?(Subscription)

  def notify(text, url \\ "/") when is_binary(text) do
    if any?(), do: Oban.insert(Worker.new(%{text: text, url: url})), else: :skipped
  end

  def deliver(text, url) do
    [title | rest] = String.split(text, "\n", parts: 2)
    payload = Jason.encode!(%{title: title, body: Enum.join(rest), url: url, tag: url})

    Subscription
    |> Repo.all()
    |> Enum.each(&send_one(&1, payload))
  end

  defp send_one(subscription, payload) do
    body = WebPush.encrypt(payload, subscription.p256dh, subscription.auth)

    headers = [
      authorization:
        WebPush.vapid_header(subscription.endpoint, keys(), BastionWeb.Endpoint.url()),
      content_encoding: "aes128gcm",
      content_type: "application/octet-stream",
      ttl: "86400",
      urgency: "high"
    ]

    case Req.post(
           subscription.endpoint,
           [body: body, headers: headers, retry: false] ++ req_options()
         ) do
      {:ok, %{status: status}} when status in 200..299 ->
        :ok

      # The browser dropped the subscription or the key changed: it will never work again.
      {:ok, %{status: status}} when status in [403, 404, 410] ->
        Repo.delete(subscription)

      {:ok, %{status: status}} ->
        Logger.warning("push was not delivered: HTTP #{status}")

      {:error, error} ->
        Logger.warning("push was not delivered: #{Exception.message(error)}")
    end
  end

  defp req_options, do: Application.get_env(:bastion, :req_options, [])
end
