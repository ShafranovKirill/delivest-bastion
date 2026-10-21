defmodule BastionWeb.InstanceChannelTest do
  use BastionWeb.ChannelCase, async: false

  alias Bastion.Instances
  alias BastionWeb.{AgentSocket, Presence}

  @token "test-agent-token"

  defp connect_agent(id, token \\ @token),
    do: connect(AgentSocket, %{"token" => token, "instance_id" => id})

  defp join_agent(id) do
    {:ok, socket} = connect_agent(id)

    {:ok, _reply, socket} =
      subscribe_and_join(socket, "instance:" <> id, %{
        "name" => "Pizza",
        "hosts" => %{"api" => "api.example.com"},
        "agent_version" => "0.1.0",
        "actions" => Instances.actions()
      })

    socket
  end

  test "rejects a wrong token and a malformed instance id" do
    assert :error = connect_agent(Ecto.UUID.generate(), "wrong")
    assert :error = connect_agent("not-a-uuid")
    assert :error = connect(AgentSocket, %{})
  end

  test "an agent can join only its own topic" do
    {:ok, socket} = connect_agent(Ecto.UUID.generate())

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "instance:" <> Ecto.UUID.generate(), %{"name" => "x"})
  end

  test "joining registers the instance and marks it online" do
    id = Ecto.UUID.generate()
    join_agent(id)

    assert [%{id: ^id, name: "Pizza", online: true}] = Instances.list_instances()
    assert MapSet.member?(Presence.online_ids(), id)
  end

  test "heartbeats are stored and commands round trip" do
    id = Ecto.UUID.generate()
    socket = join_agent(id)

    ref = push(socket, "heartbeat", Bastion.Fixtures.healthy_status())
    assert_reply ref, :ok
    assert %{status: %{"disk" => _}} = Instances.get_instance(id)

    {:ok, command} = Instances.send_command(Instances.get_instance(id), "restart", %{}, "admin")
    command_id = command.id
    assert_push "command", %{"id" => ^command_id, "action" => "restart", "args" => %{}}

    ref = push(socket, "command_started", %{"id" => command_id})
    assert_reply ref, :ok

    ref = push(socket, "command_result", %{"id" => command_id, "ok" => true, "output" => "done"})
    assert_reply ref, :ok

    assert [%{status: "ok", output: "done", requested_by: "admin"}] = Instances.list_commands(id)
  end
end
