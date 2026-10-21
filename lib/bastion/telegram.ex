defmodule Bastion.Telegram do
  @api "https://api.telegram.org"

  def token, do: Application.get_env(:bastion, :telegram_bot_token)
  def chat_id, do: Application.get_env(:bastion, :telegram_chat_id)

  def configured?, do: is_binary(token()) and not is_nil(chat_id())

  # Without a chat id the bot still runs, so it can tell the chat id to whoever writes to it.
  def polling?,
    do: is_binary(token()) and Application.get_env(:bastion, :telegram_polling, true)

  def allowed_chat?(chat_id), do: chat_id() != nil and to_string(chat_id) == to_string(chat_id())

  def send_message(text, params \\ %{}),
    do: call("sendMessage", Map.merge(%{chat_id: chat_id(), text: text}, params))

  def call(method, params, opts \\ []) do
    case token() do
      nil ->
        {:error, :not_configured}

      token ->
        case Req.post(
               "#{@api}/bot#{token}/#{method}",
               [json: params, retry: false] ++ opts ++ req_options()
             ) do
          {:ok, %{status: 200, body: %{"ok" => true} = body}} -> {:ok, body["result"]}
          {:ok, %{body: %{"description" => description}}} -> {:error, description}
          {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
          {:error, error} -> {:error, Exception.message(error)}
        end
    end
  end

  def escape(text) do
    text
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
  end

  def keyboard(rows) do
    %{
      inline_keyboard:
        Enum.map(rows, fn row ->
          Enum.map(row, fn {text, data} -> %{text: text, callback_data: data} end)
        end)
    }
  end

  defp req_options, do: Application.get_env(:bastion, :req_options, [])
end
