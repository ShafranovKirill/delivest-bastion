defmodule Bastion.Telegram.Cards do
  @moduledoc "Site cards in the chat that wait for a command sent from them, by command id."

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(command_id, chat_id, message_id),
    do: Agent.update(__MODULE__, &Map.put(&1, command_id, {chat_id, message_id}))

  def get(command_id), do: Agent.get(__MODULE__, &Map.get(&1, command_id))

  def delete(command_id), do: Agent.update(__MODULE__, &Map.delete(&1, command_id))

  def confirm(data) do
    token = Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
    now = System.monotonic_time(:second)

    Agent.update(__MODULE__, fn cards ->
      cards =
        Map.reject(cards, fn
          {{:confirmation, _}, {expires, _}} -> expires <= now
          _ -> false
        end)

      Map.put(cards, {:confirmation, token}, {now + 600, data})
    end)

    token
  end

  def confirmation(token) do
    case Agent.get(__MODULE__, &Map.get(&1, {:confirmation, token})) do
      {expires, data} ->
        if expires > System.monotonic_time(:second), do: data

      nil ->
        nil
    end
  end
end
