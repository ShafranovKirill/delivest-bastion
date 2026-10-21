defmodule BastionWeb.AgentSocket do
  use Phoenix.Socket

  channel "instance:*", BastionWeb.InstanceChannel

  @impl true
  def connect(%{"token" => token, "instance_id" => instance_id}, socket, _connect_info)
      when is_binary(token) and is_binary(instance_id) do
    with true <- valid_token?(token),
         {:ok, instance_id} <- Ecto.UUID.cast(instance_id) do
      {:ok, assign(socket, :instance_id, instance_id)}
    else
      _ -> :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "agent:#{socket.assigns.instance_id}"

  defp valid_token?(token) do
    expected = Application.get_env(:bastion, :agent_token)
    is_binary(expected) and Plug.Crypto.secure_compare(token, expected)
  end
end
