defmodule BastionWeb.NodeLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Bastion.Nodes

  test "owner sees nodes and can command a selected prepared installation", %{conn: conn} do
    instance_id = Ecto.UUID.generate()
    {:ok, node, _} = Nodes.create_node("Test server")
    conn = init_test_session(conn, %{"admin" => "admin"})

    {:ok, _, overview} = live(conn, ~p"/")
    assert overview =~ "Test server"
    {:ok, _, list} = live(conn, ~p"/nodes")
    assert list =~ "Test server"

    {:ok, detail, html} = live(conn, ~p"/nodes/#{node.id}")
    assert html =~ "Подготовленная установка"

    detail
    |> form("#prepare-instance",
      placement: %{
        instance_id: instance_id,
        name: "Pilot A",
        project_name: "pilot-a",
        gateway_port: "18080"
      }
    )
    |> render_submit()

    assert render(detail) =~ "Pilot A"
    detail |> element("button[phx-value-action='stop']") |> render_click()
    assert [%{action: "stop", instance_id: id}] = Nodes.operations_for(instance_id)
    assert id == instance_id

    {:ok, _, journal} = live(conn, ~p"/operations")
    assert journal =~ "Pilot A"
    assert journal =~ "Ожидает"
  end

  test "registration endpoint consumes token once", %{conn: conn} do
    {:ok, node, token} = Nodes.create_node("Test server")
    payload = %{"token" => token, "protocol_version" => 1}

    body = conn |> post(~p"/node/register", payload) |> json_response(200)
    assert body["node_id"] == node.id
    assert is_binary(body["credential"])
    assert conn |> post(~p"/node/register", payload) |> json_response(401)
  end

  test "SSH form validates identity and retry keeps the same node", %{conn: conn} do
    Application.put_env(:bastion, :node_ssh_runner, Bastion.FakeNodeSshRunner)
    Application.put_env(:bastion, :ssh_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:bastion, :node_ssh_runner)
      Application.delete_env(:bastion, :ssh_test_pid)
    end)

    conn = init_test_session(conn, %{"admin" => "admin"})
    {:ok, list, _} = live(conn, ~p"/nodes")

    params = %{
      name: "New pilot",
      host: "pilot.example.org",
      port: "22",
      login: "root",
      fingerprint: "SHA256:" <> String.duplicate("B", 43),
      password: "secret"
    }

    list |> form("#install-node", node: %{params | fingerprint: "wrong"}) |> render_submit()
    assert Nodes.list_nodes() == []
    list |> form("#install-node", node: params) |> render_submit()
    assert_receive {:ssh_started, task, id}
    assert length(Nodes.list_nodes()) == 1
    {:ok, detail, _} = live(conn, ~p"/nodes/#{id}")
    assert has_element?(detail, "#retry-node-install")
    ref = Process.monitor(task)
    send(task, :continue)
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
    detail |> form("#retry-node-install", node: Map.delete(params, :name)) |> render_submit()
    assert_receive {:ssh_started, task2, ^id}
    assert length(Nodes.list_nodes()) == 1
    ref2 = Process.monitor(task2)
    send(task2, :continue)
    assert_receive {:DOWN, ^ref2, :process, ^task2, :normal}
  end
end
