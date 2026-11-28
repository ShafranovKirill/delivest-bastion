defmodule BastionWeb.NodeChannelTest do
  use BastionWeb.ChannelCase, async: false

  alias Bastion.Nodes
  alias BastionWeb.NodeSocket

  test "node can join only its own topic and command results are scoped" do
    first_id = Ecto.UUID.generate()
    second_id = Ecto.UUID.generate()
    {:ok, node, token} = Nodes.create_node("pilot")
    {:ok, _, credential} = Nodes.register(token, 1)
    {:ok, _} = Nodes.prepare_instance(node.id, first_id, "First", %{}, "pilot-a", 18080)
    {:ok, _} = Nodes.prepare_instance(node.id, second_id, "Second", %{}, "pilot-b", 18081)

    assert :error =
             connect(NodeSocket, %{},
               connect_info: %{x_headers: [{"x-delivest-node-token", "wrong"}]}
             )

    {:ok, socket} =
      connect(NodeSocket, %{},
        connect_info: %{x_headers: [{"x-delivest-node-token", credential}]}
      )

    assert {:error, %{reason: "unauthorized"}} =
             subscribe_and_join(socket, "node:" <> Ecto.UUID.generate(), %{
               "protocol_version" => 1
             })

    {:ok, _, socket} = subscribe_and_join(socket, "node:" <> node.id, %{"protocol_version" => 1})

    {:ok, operation} = Nodes.queue(first_id, "stop", "admin")
    assert_push "command", %{operation_id: id, instance_id: target_id, action: "stop"}
    assert id == operation.id
    assert target_id == first_id

    ref =
      push(socket, "command_result", %{"operation_id" => Ecto.UUID.generate(), "status" => "ok"})

    assert_reply ref, :error, %{reason: "operation_not_found"}

    ref = push(socket, "command_ack", %{"operation_id" => operation.id})
    assert_reply ref, :ok

    ref =
      push(socket, "command_result", %{
        "operation_id" => operation.id,
        "status" => "ok",
        "result" => %{}
      })

    assert_reply ref, :ok
    assert Nodes.operations_for(first_id) |> hd() |> Map.get(:status) == "ok"
    assert Nodes.operations_for(second_id) == []

    {:ok, _} = Nodes.revoke(Nodes.get_node(node.id))
    ref = push(socket, "heartbeat", %{})
    assert_reply ref, :error
  end
end
