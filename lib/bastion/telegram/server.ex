defmodule Bastion.Telegram.Server do
  @moduledoc "Registers the bot transport and queues updates and command notifications."

  use GenServer

  require Logger

  alias Bastion.{Instances, Telegram}
  alias Bastion.Telegram.{Bot, UpdateWorker}

  @poll_timeout 25
  @retry_ms 5_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Instances.subscribe()
    send(self(), :setup)
    {:ok, %{offset: nil, poll: nil}}
  end

  @impl true
  def handle_info(:setup, state) do
    case Bot.setup() do
      :ok ->
        {:noreply, poll(state)}

      {:error, _reason} ->
        Logger.warning("telegram transport setup failed; retrying")
        Process.send_after(self(), :setup, @retry_ms)
        {:noreply, state}
    end
  end

  def handle_info(:poll, state), do: {:noreply, poll(state)}

  def handle_info({ref, result}, %{poll: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, updates} when is_list(updates) ->
        case enqueue_updates(updates, state.offset) do
          {:ok, offset} -> {:noreply, poll(%{state | poll: nil, offset: offset})}
          {:error, offset} -> {:noreply, retry(%{state | offset: offset})}
        end

      _error ->
        Logger.warning("telegram polling failed; retrying")
        {:noreply, retry(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{poll: %Task{ref: ref}} = state) do
    Logger.warning("telegram polling task exited; retrying")
    {:noreply, retry(state)}
  end

  def handle_info({:command_updated, command}, state) do
    case UpdateWorker.enqueue_command(command) do
      {:ok, _job} -> :ok
      {:error, _reason} -> Logger.error("telegram command notification enqueue failed")
    end

    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp enqueue_updates(updates, offset) do
    Enum.reduce_while(updates, {:ok, offset}, fn
      %{"update_id" => id} = update, {:ok, offset} when is_integer(id) ->
        case UpdateWorker.enqueue_update(update) do
          {:ok, _job} -> {:cont, {:ok, max(id + 1, offset || 0)}}
          {:error, _reason} -> {:halt, {:error, offset}}
        end

      _, {:ok, offset} ->
        {:halt, {:error, offset}}
    end)
  end

  defp poll(%{poll: %Task{}} = state), do: state

  defp poll(state) do
    if Telegram.polling?(), do: start_poll(state), else: state
  end

  defp start_poll(state) do
    params = %{
      timeout: @poll_timeout,
      allowed_updates: Telegram.allowed_updates()
    }

    params = if state.offset, do: Map.put(params, :offset, state.offset), else: params

    task =
      Task.Supervisor.async_nolink(Bastion.TaskSupervisor, fn ->
        Telegram.call("getUpdates", params,
          retry: false,
          receive_timeout: (@poll_timeout + 10) * 1000
        )
      end)

    %{state | poll: task}
  end

  defp retry(state) do
    Process.send_after(self(), :poll, @retry_ms)
    %{state | poll: nil}
  end
end
