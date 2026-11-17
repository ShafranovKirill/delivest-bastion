defmodule BastionWeb.TelegramController do
  use BastionWeb, :controller

  alias Bastion.Telegram
  alias Bastion.Telegram.UpdateWorker

  def create(conn, params) do
    case get_req_header(conn, "x-telegram-bot-api-secret-token") do
      [secret] ->
        if Telegram.webhook?() and Telegram.authenticate_webhook?(secret),
          do: accept_update(conn, params),
          else: send_resp(conn, :unauthorized, "")

      _ ->
        send_resp(conn, :unauthorized, "")
    end
  end

  defp accept_update(conn, %{"update_id" => id} = update) when is_integer(id) do
    acknowledgement = acknowledgement(update)
    update = Map.put(update, "_telegram_acknowledged", acknowledgement != nil)

    case UpdateWorker.enqueue_update(update) do
      {:ok, _job} -> json(conn, acknowledgement || %{ok: true})
      {:error, _reason} -> send_resp(conn, :service_unavailable, "")
    end
  rescue
    _error in [DBConnection.ConnectionError, Postgrex.Error] ->
      send_resp(conn, :service_unavailable, "")
  end

  defp accept_update(conn, _params), do: send_resp(conn, :bad_request, "")

  defp acknowledgement(%{
         "callback_query" => %{"id" => id, "message" => %{"chat" => %{"id" => chat_id}}}
       })
       when is_binary(id) and byte_size(id) > 0 do
    if Telegram.allowed_chat?(chat_id),
      do: %{method: "answerCallbackQuery", callback_query_id: id}
  end

  defp acknowledgement(_), do: nil
end
