defmodule BastionWeb.NodeChannelTest do
  use BastionWeb.ChannelCase, async: false

  alias Bastion.Nodes
  alias Bastion.Nodes.Operation
  alias Bastion.Repo
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

  test "bootstrap credentials are encrypted, acknowledged after commit and scoped to a placement" do
    {:ok, node, token} = Nodes.create_node("pilot")
    {:ok, _, credential} = Nodes.register(token, 1)
    id = Ecto.UUID.generate()
    {:ok, placement} = Nodes.prepare_instance(node.id, id, "Cafe", %{}, "delivest-cafe", 20_000)

    %Operation{
      node_id: node.id,
      instance_id: id,
      placement_id: placement.id,
      placement_revision: placement.revision
    }
    |> Operation.changeset(%{action: "instance_create", status: "running", args: %{}})
    |> Repo.insert!()

    {:ok, socket} =
      connect(NodeSocket, %{},
        connect_info: %{x_headers: [{"x-delivest-node-token", credential}]}
      )

    {:ok, _, socket} = subscribe_and_join(socket, "node:" <> node.id, %{"protocol_version" => 1})

    payload = %{
      "instance_id" => id,
      "placement_revision" => 1,
      "admin_login" => "admin123",
      "admin_password" => "a-unique-secret-123456"
    }

    ref = push(socket, "bootstrap_credentials", payload)
    assert_reply ref, :ok
    assert_push "bootstrap_credentials_ack", %{instance_id: ^id, placement_revision: 1}

    instance = Repo.get!(Bastion.Instances.Instance, id)
    assert instance.admin_login == "admin123"
    refute instance.admin_password_encrypted == payload["admin_password"]

    assert {:ok, payload["admin_password"]} ==
             Bastion.Credentials.decrypt(instance.admin_password_encrypted)

    ref = push(socket, "bootstrap_credentials", payload)
    assert_reply ref, :ok
    assert_push "bootstrap_credentials_ack", %{instance_id: ^id, placement_revision: 1}

    ref =
      push(socket, "bootstrap_credentials", %{
        payload
        | "admin_password" => "different-secret-123456"
      })

    assert_reply ref, :error, %{reason: "invalid_bootstrap_credentials"}

    ref = push(socket, "bootstrap_credentials", %{payload | "placement_revision" => 2})
    assert_reply ref, :error, %{reason: "invalid_bootstrap_credentials"}

    {:ok, _} = Nodes.revoke(Nodes.get_node(node.id))
    ref = push(socket, "bootstrap_credentials", payload)
    assert_reply ref, :error, %{reason: "invalid_bootstrap_credentials"}
  end
end
