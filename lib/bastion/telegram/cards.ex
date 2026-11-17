defmodule Bastion.Telegram.Cards do
  @moduledoc "Site cards in the chat that wait for a command sent from them, by command id."

  use Agent

  def start_link(_opts), do: Agent.start_link(fn -> %{} end, name: __MODULE__)

  def put(command_id, chat_id, message_id),
    do: Agent.update(__MODULE__, &Map.put(&1, command_id, {chat_id, message_id}))

  def put_widget(command_id, chat_id, message_id),
    do: Agent.update(__MODULE__, &Map.put(&1, command_id, {:widget, chat_id, message_id}))

  def session(chat_id, message_id), do: get({:widget, chat_id, message_id})

  def session(chat_id, message_id, session) do
    Agent.update(__MODULE__, fn state ->
      now = System.monotonic_time(:second)

      state
      |> Map.reject(fn
        {{:widget, _, _}, %{expires: expires}} -> expires <= now
        _ -> false
      end)
      |> Map.put({:widget, chat_id, message_id}, session)
    end)
  end

  def consume(chat_id, message_id, token, action) do
    Agent.get_and_update(__MODULE__, fn state ->
      key = {:widget, chat_id, message_id}

      case state[key] do
        %{token: ^token, actions: actions, expires: expires} = session ->
          if action in actions and expires > System.monotonic_time(:second),
            do: {{:ok, session}, Map.delete(state, key)},
            else: {:error, state}

        _ ->
          {:error, state}
      end
    end)
  end

  def get(command_id), do: Agent.get(__MODULE__, &Map.get(&1, command_id))

  def delete(command_id), do: Agent.update(__MODULE__, &Map.delete(&1, command_id))
end
