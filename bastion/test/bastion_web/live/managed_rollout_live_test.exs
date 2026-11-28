defmodule BastionWeb.ManagedRolloutLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  test "renders the rollout form and rejects an empty selected group", %{conn: conn} do
    conn = init_test_session(conn, %{"admin" => "admin"})
    {:ok, view, _html} = live(conn, ~p"/instances")

    assert has_element?(view, "#managed-rollout-form select[name='managed_rollout[scope]']")
    assert has_element?(view, "#managed-rollout-form select[name='managed_rollout[canary_id]']")

    view
    |> form("#managed-rollout-form", managed_rollout: %{scope: "selected", canary_id: ""})
    |> render_submit()

    assert render(view) =~ "empty_selection"
  end
end
