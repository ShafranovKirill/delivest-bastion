defmodule Bastion.Rollout do
  @moduledoc """
  Updates the sites one by one: the next site starts only after the previous one finished
  its update and answers again, and the first failure stops the rest.
  """

  use GenServer

  alias Bastion.{Alerts, Health, Images, Instances, Updates}
  alias Bastion.Instances.Instance

  @topic "instances"
  @command_timeout_seconds 45 * 60
  @verify_timeout_seconds 6 * 60

  defstruct status: :idle,
            queue: [],
            done: [],
            current: nil,
            command_id: nil,
            phase: nil,
            started_at: nil,
            deadline: nil,
            requested_by: nil,
            error: nil

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def state, do: GenServer.call(__MODULE__, :state)
  def start(requested_by), do: GenServer.call(__MODULE__, {:start, requested_by})
  def cancel(requested_by), do: GenServer.call(__MODULE__, {:cancel, requested_by})

  def running?(%__MODULE__{status: :running}), do: true
  def running?(_state), do: false

  @doc "Online sites that are not stopped on purpose and are behind the registry or not known to be up to date."
  def candidates do
    Instances.list_instances()
    |> Enum.filter(fn instance ->
      instance.online and is_nil(instance.stopped_at) and "update" in instance.actions and
        Images.up_to_date?(instance) != true
    end)
  end

  @impl true
  def init(_opts) do
    Instances.subscribe()
    {:ok, %__MODULE__{}}
  end

  @impl true
  def handle_call(:state, _from, state), do: {:reply, state, state}

  def handle_call({:start, _requested_by}, _from, %{status: :running} = state),
    do: {:reply, {:error, :already_running}, state}

  def handle_call({:start, requested_by}, _from, _state) do
    case candidates() do
      [] ->
        {:reply, {:error, :nothing_to_update}, %__MODULE__{}}

      instances ->
        Alerts.send_message(
          "🚀 Обновление по очереди (#{requested_by}): " <>
            Enum.map_join(instances, ", ", & &1.name)
        )

        state = %__MODULE__{
          status: :running,
          queue: Enum.map(instances, & &1.id),
          started_at: now(),
          requested_by: requested_by
        }

        {:reply, :ok, state |> next() |> publish()}
    end
  end

  def handle_call({:cancel, requested_by}, _from, %{status: :running} = state) do
    Alerts.send_message(
      "⏹ Обновление по очереди отменено (#{requested_by}). " <>
        "Начатое обновление #{name(state.current)} доиграет само."
    )

    {:reply, :ok, publish(%{state | status: :cancelled, queue: [], phase: nil})}
  end

  def handle_call({:cancel, _requested_by}, _from, state), do: {:reply, :ok, state}

  @impl true
  def handle_info(
        {:command_updated, %{id: id, status: status} = command},
        %{status: :running, command_id: id, phase: :command} = state
      )
      when status in ["ok", "error"] do
    state =
      if status == "ok" do
        Process.send_after(self(), :verify, verify_ms())
        %{state | phase: :verify, deadline: DateTime.add(now(), @verify_timeout_seconds)}
      else
        stop(state, "обновление закончилось ошибкой:\n" <> last_lines(command.output))
      end

    {:noreply, publish(state)}
  end

  def handle_info(:verify, %{status: :running, phase: :verify} = state) do
    instance = Instances.get_instance(state.current)
    health = instance && Health.evaluate(instance)

    state =
      cond do
        instance && health.level in [:ok, :warning] and checked_after_update?(instance, state) ->
          next(%{state | done: state.done ++ [state.current]})

        DateTime.compare(now(), state.deadline) == :gt ->
          problems = if health, do: Enum.join(health.problems, "; "), else: "сайт удалён"
          stop(state, "сайт не ответил после обновления: #{problems}")

        true ->
          Process.send_after(self(), :verify, verify_ms())
          state
      end

    {:noreply, publish(state)}
  end

  def handle_info(:command_timeout, %{status: :running, phase: :command} = state) do
    if DateTime.compare(now(), state.deadline) == :gt,
      do: {:noreply, publish(stop(state, "агент не закончил обновление за 45 минут"))},
      else: {:noreply, state}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp next(%{queue: []} = state) do
    Alerts.send_message(
      "✅ Обновление по очереди закончено: " <> Enum.map_join(state.done, ", ", &name/1)
    )

    %{state | status: :done, current: nil, command_id: nil, phase: nil}
  end

  defp next(%{queue: [id | rest]} = state) do
    state = %{state | queue: rest, current: id}

    case Instances.get_instance(id) do
      %Instance{online: true, stopped_at: nil} = instance ->
        case Updates.update(instance, "#{state.requested_by} · по очереди") do
          {:ok, command} ->
            Process.send_after(self(), :command_timeout, @command_timeout_seconds * 1000 + 1000)

            %{
              state
              | command_id: command.id,
                phase: :command,
                deadline: DateTime.add(now(), @command_timeout_seconds)
            }

          {:error, reason} ->
            stop(state, "обновление не отправлено: #{inspect(reason)}")
        end

      _ ->
        stop(state, "сайт не на связи или выключен")
    end
  end

  defp stop(state, reason) do
    left = Enum.map_join(state.queue, ", ", &name/1)

    Alerts.send_message(
      "⛔ Обновление по очереди остановлено на #{name(state.current)}: #{reason}" <>
        if(left != "", do: "\nНе обновлялись: #{left}", else: "")
    )

    %{state | status: :failed, phase: nil, error: reason}
  end

  # The external check of the bastion runs every minute; one made after the update
  # tells the site answers from outside too.
  defp checked_after_update?(%Instance{checked_at: checked_at}, state) do
    finished =
      case Enum.find(Instances.list_commands(state.current, 5), &(&1.id == state.command_id)) do
        %{finished_at: %DateTime{} = at} -> at
        _ -> state.started_at
      end

    checked_at && DateTime.compare(checked_at, finished) == :gt
  end

  defp publish(state) do
    Phoenix.PubSub.broadcast(Bastion.PubSub, @topic, {:rollout_updated, state})
    state
  end

  defp name(nil), do: "—"

  defp name(id) do
    case Instances.get_instance(id) do
      nil -> id
      instance -> instance.name
    end
  end

  defp last_lines(nil), do: "агент вернул ошибку"

  defp last_lines(output),
    do: output |> String.split("\n", trim: true) |> Enum.take(-8) |> Enum.join("\n")

  defp verify_ms, do: Application.get_env(:bastion, :rollout_verify_ms, 15_000)

  defp now, do: DateTime.utc_now(:second)
end
