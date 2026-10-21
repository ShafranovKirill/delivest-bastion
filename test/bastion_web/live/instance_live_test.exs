defmodule BastionWeb.InstanceLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Bastion.Fixtures

  alias Bastion.Instances
  alias BastionWeb.Presence

  defp log_in(conn), do: init_test_session(conn, %{"admin" => "admin"})

  defp bring_online(instance) do
    test_pid = self()

    pid =
      spawn_link(fn ->
        Instances.subscribe_commands(instance.id)
        {:ok, _} = Presence.track_agent(self(), instance.id)
        send(test_pid, :online)

        receive_loop = fn loop ->
          receive do
            {:push_command, command} -> send(test_pid, {:agent_got, command.action, command.args})
          end

          loop.(loop)
        end

        receive_loop.(receive_loop)
      end)

    assert_receive :online
    pid
  end

  test "pages require a login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, ~p"/")
    assert redirected_to(get(conn, ~p"/")) == ~p"/login"
  end

  test "login with the configured credentials", %{conn: conn} do
    conn = post(conn, ~p"/login", %{"session" => %{"login" => "admin", "password" => "nope"}})
    assert html_response(conn, 200) =~ "Неверный логин или пароль"

    conn =
      post(build_conn(), ~p"/login", %{"session" => %{"login" => "admin", "password" => "secret"}})

    assert redirected_to(conn) == ~p"/"
  end

  test "lists instances with their state and updates live", %{conn: conn} do
    instance = instance_fixture(%{info: %{"name" => "Pizza North"}})
    {:ok, lv, html} = live(log_in(conn), ~p"/")

    assert html =~ "Pizza North"
    refute has_element?(lv, "#update-all")

    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    assert render(lv) =~ "40%"
  end

  test "sends commands to an online agent", %{conn: conn} do
    instance = instance_fixture()
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")
    assert has_element?(lv, "#containers", "server")

    lv |> element("#instance-actions button", "Обновить") |> render_click()
    assert_receive {:agent_got, "update", %{}}
    assert has_element?(lv, "[id^=command-]", "Обновление")

    [command] = Instances.list_commands(instance.id)
    Instances.command_finished(instance.id, command.id, true, "all good")
    assert render(lv) =~ "all good"
  end

  test "logs request picks a service and tail", %{conn: conn} do
    instance = instance_fixture()
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")

    lv |> form("#logs-form", %{"service" => "server", "tail" => "50"}) |> render_submit()
    assert_receive {:agent_got, "logs", %{"service" => "server", "tail" => "50"}}
  end

  test "reads the .env and saves the edited one", %{conn: conn} do
    instance = instance_fixture()
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")
    refute has_element?(lv, "#env-form")

    lv |> element("#env-load") |> render_click()
    assert_receive {:agent_got, "env_read", %{}}

    [command] = Instances.list_commands(instance.id)
    Instances.command_finished(instance.id, command.id, true, "PHX_HOST=a.example.com\n")

    assert has_element?(lv, "#env-form textarea", "PHX_HOST=a.example.com")
    refute render(lv) =~ "<pre"

    lv |> form("#env-form", %{"content" => "PHX_HOST=b.example.com\n"}) |> render_submit()
    assert_receive {:agent_got, "env_write", %{"content" => "PHX_HOST=b.example.com\n"}}
  end

  test "offline agents get no commands and can be removed", %{conn: conn} do
    instance = instance_fixture()
    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")

    assert lv |> element("#instance-actions button", "Обновить") |> render() =~ "disabled"

    lv |> element("#delete-instance") |> render_click()
    assert_redirect(lv, ~p"/")
    assert Instances.list_instances() == []
  end
end
