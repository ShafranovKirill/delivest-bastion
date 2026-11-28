defmodule BastionWeb.ManagedMoveLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Bastion.Nodes

  test "renders move reservation under the administrator session", %{conn: conn} do
    {:ok, node, _} = Nodes.create_node("source")
    id = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, id, "Shop", %{}, "shop", 18080)

    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/instances/#{id}/move")

    conn = init_test_session(conn, %{"admin" => "admin"})
    {:ok, view, _html} = live(conn, ~p"/instances/#{id}/move")
    assert has_element?(view, "#move-form")
    assert has_element?(view, "select[name='move[node_id]']")
  end
end
