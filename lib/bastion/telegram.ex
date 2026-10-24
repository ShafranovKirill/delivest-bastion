defmodule Bastion.Telegram do
  @api "https://api.telegram.org"

  def token, do: Application.get_env(:bastion, :telegram_bot_token)
  def chat_id, do: Application.get_env(:bastion, :telegram_chat_id)

  def configured?, do: is_binary(token()) and not is_nil(chat_id())

  # Without a chat id the bot still runs, so it can tell the chat id to whoever writes to it.
  def polling?,
    do: is_binary(token()) and Application.get_env(:bastion, :telegram_polling, true)

  def allowed_chat?(chat_id), do: chat_id() != nil and to_string(chat_id) == to_string(chat_id())

  # Chats with a person have positive ids, groups negative ones.
  def private_chat? do
    case Integer.parse(to_string(chat_id())) do
      {id, ""} -> id > 0
      _ -> false
    end
  end

  def send_message(text, params \\ %{}),
    do: call("sendMessage", Map.merge(%{chat_id: chat_id(), text: text}, params))

  def send_document(filename, content, params \\ %{}) do
    fields =
      params
      |> Map.put_new(:chat_id, chat_id())
      |> Enum.map(fn {key, value} -> {key, encode_field(value)} end)

    call("sendDocument", nil,
      form_multipart:
        fields ++ [document: {content, filename: filename, content_type: "text/plain"}]
    )
  end

  defp encode_field(value) when is_map(value), do: Jason.encode!(value)
  defp encode_field(value), do: to_string(value)

  # Pooled connections to Telegram go stale while the bastion is idle and a request sent
  # into one only times out, so a request is sent again over a fresh connection.
  @retry [retry: :transient, max_retries: 2, retry_delay: 500, receive_timeout: 10_000]

  def call(method, params, opts \\ []) do
    case token() do
      nil ->
        {:error, :not_configured}

      token ->
        case Req.post(
               "#{@api}/bot#{token}/#{method}",
               body(params) ++ @retry ++ opts ++ req_options()
             ) do
          {:ok, %{status: 200, body: %{"ok" => true} = body}} -> {:ok, body["result"]}
          {:ok, %{body: %{"description" => description}}} -> {:error, description}
          {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
          {:error, error} -> {:error, Exception.message(error)}
        end
    end
  end

  defp body(nil), do: []
  defp body(params), do: [json: params]

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
          Enum.map(row, fn
            {text, {:url, url}} -> %{text: text, url: url}
            {text, data} -> %{text: text, callback_data: data}
          end)
        end)
    }
  end

  defp req_options, do: Application.get_env(:bastion, :req_options, [])
end
