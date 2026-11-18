defmodule Bastion.Landing.RateLimiter do
  use GenServer

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    :ets.new(__MODULE__, [:named_table, :public, :set, write_concurrency: true])
    :timer.send_interval(60_000, :prune)
    {:ok, nil}
  end

  def allow?(key, limit) do
    bucket = System.system_time(:second) |> div(60)
    :ets.update_counter(__MODULE__, {key, bucket}, {2, 1}, {{key, bucket}, 0}) <= limit
  end

  def handle_info(:prune, state) do
    cutoff = System.system_time(:second) |> div(60) |> Kernel.-(2)
    :ets.select_delete(__MODULE__, [{{{:"$1", :"$2"}, :_}, [{:<, :"$2", cutoff}], [true]}])
    {:noreply, state}
  end
end
