defmodule Bastion.Telegram.Cards do
  @moduledoc "Site cards in the chat that wait for a command sent from them, by command id."

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(command_id, chat_id, message_id),
    do: Agent.update(__MODULE__, &Map.put(&1, command_id, {chat_id, message_id}))

  def get(command_id), do: Agent.get(__MODULE__, &Map.get(&1, command_id))

  def delete(command_id), do: Agent.update(__MODULE__, &Map.delete(&1, command_id))
end
