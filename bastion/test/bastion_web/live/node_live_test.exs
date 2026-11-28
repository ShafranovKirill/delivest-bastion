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
end
