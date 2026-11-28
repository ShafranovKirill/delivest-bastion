defmodule Bastion.Domains.RegRuRateLimiter do
  use GenServer

  def start_link(_opts), do: GenServer.start_link(__MODULE__, {0, 0}, name: __MODULE__)
  def allow?, do: GenServer.call(__MODULE__, :allow)

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call(:allow, _from, {hour, count}) do
    current = System.system_time(:second) |> div(3600)
    used = if current == hour, do: count, else: 0

    if used < 600 do
      {:reply, true, {current, used + 1}}
    else
      {:reply, false, {current, used}}
    end
  end
end
