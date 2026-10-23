defmodule Bastion.Telegram.Server do
  @moduledoc "Long polls the bot updates and reports finished commands to the chat."

  use GenServer

  require Logger

  alias Bastion.{Instances, Telegram}
  alias Bastion.Telegram.Bot

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
    Bot.setup()
    {:noreply, poll(state)}
  end

  def handle_info(:poll, state), do: {:noreply, poll(state)}

  def handle_info({ref, result}, %{poll: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])

    case result do
      {:ok, updates} when is_list(updates) ->
        offset = Enum.reduce(updates, state.offset, &handle_update/2)
        {:noreply, poll(%{state | poll: nil, offset: offset})}

      error ->
        Logger.warning("telegram polling failed: #{inspect(error)}")
        {:noreply, retry(state)}
    end
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{poll: %Task{ref: ref}} = state) do
    Logger.warning("telegram polling crashed: #{inspect(reason)}")
    {:noreply, retry(state)}
  end

  def handle_info({:command_updated, command}, state) do
    safely(fn -> Bot.command_finished(command) end)
    {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp handle_update(update, _offset) do
    safely(fn -> Bot.handle_update(update) end)
    update["update_id"] + 1
  end

  defp poll(state) do
    params = %{timeout: @poll_timeout, allowed_updates: ["message", "callback_query"]}
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

  defp safely(fun) do
    fun.()
  rescue
    error ->
      Logger.error("telegram bot failed: " <> Exception.format(:error, error, __STACKTRACE__))
  end
end
