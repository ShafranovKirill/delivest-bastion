defmodule Bastion.LoginCodes do
  @moduledoc """
  The second login step: a one-time code sent to the admin in Telegram.

  Codes live in this process and the session only carries a random id, so a copied
  cookie cannot reset the attempts.
  """

  use Agent

  require Logger

  alias Bastion.Telegram

  @ttl_seconds 300
  @max_attempts 5

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def ttl_minutes, do: div(@ttl_seconds, 60)

  def chat_id, do: Application.get_env(:bastion, :telegram_login_chat_id) || Telegram.chat_id()

  def required?, do: is_binary(Telegram.token()) and not is_nil(chat_id())

  def issue(login, ip) do
    code =
      1_000_000
      |> :rand.uniform()
      |> Kernel.-(1)
      |> Integer.to_string()
      |> String.pad_leading(6, "0")

    id = 24 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

    text = """
    🔐 Код входа в Бастион: <code>#{code}</code>
    Действует #{ttl_minutes()} минут. Вход под #{Telegram.escape(login)} с IP #{Telegram.escape(ip)}.
    Если входите не вы, смените ADMIN_PASSWORD.
    """

    case Telegram.send_message(text, %{chat_id: chat_id(), parse_mode: "HTML"}) do
      {:ok, _message} ->
        entry = %{
          login: login,
          digest: digest(id, code),
          expires_at: now() + @ttl_seconds,
          attempts: 0
        }

        Agent.update(__MODULE__, &(&1 |> prune() |> Map.put(id, entry)))
        {:ok, id}

      {:error, reason} ->
        Logger.warning("login code was not sent: #{inspect(reason)}")
        {:error, reason}
    end
  end

  def pending?(id) when is_binary(id),
    do: Agent.get(__MODULE__, &Map.has_key?(prune(&1), id))

  def pending?(_id), do: false

  def verify(id, code) when is_binary(id) and is_binary(code) do
    Agent.get_and_update(__MODULE__, fn codes ->
      codes = prune(codes)

      case Map.fetch(codes, id) do
        :error ->
          {{:error, :expired}, codes}

        {:ok, entry} ->
          cond do
            Plug.Crypto.secure_compare(digest(id, String.trim(code)), entry.digest) ->
              {{:ok, entry.login}, Map.delete(codes, id)}

            entry.attempts + 1 >= @max_attempts ->
              {{:error, :too_many_attempts}, Map.delete(codes, id)}

            true ->
              {{:error, :invalid}, Map.put(codes, id, %{entry | attempts: entry.attempts + 1})}
          end
      end
    end)
  end

  def verify(_id, _code), do: {:error, :expired}

  defp digest(id, code) do
    secret = BastionWeb.Endpoint.config(:secret_key_base)
    :crypto.mac(:hmac, :sha256, secret, id <> ":" <> code)
  end

  defp prune(codes) do
    now = now()
    Map.reject(codes, fn {_id, entry} -> entry.expires_at <= now end)
  end

  defp now, do: System.system_time(:second)
end
