defmodule BastionWeb.Presence do
  use Phoenix.Presence, otp_app: :bastion, pubsub_server: Bastion.PubSub

  @topic "agents"

  def topic, do: @topic

  def track_agent(pid, instance_id),
    do: track(pid, @topic, instance_id, %{online_at: System.system_time(:second)})

  def online_ids, do: @topic |> list() |> Map.keys() |> MapSet.new()
end
