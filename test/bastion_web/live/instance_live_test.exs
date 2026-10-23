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
    assert_patch(lv, ~p"/instances/#{instance.id}?tab=logs")
    assert has_element?(lv, "[id^=command-]", "Обновление")

    [command] = Instances.list_commands(instance.id)
    Instances.command_finished(instance.id, command.id, true, "all good")
    assert render(lv) =~ "all good"
  end

  test "a site updated by the agent can be rolled back", %{conn: conn} do
    instance = instance_fixture()
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")
    refute has_element?(lv, "#rollback")

    status = Map.put(healthy_status(), "rollback", %{"at" => "2026-10-23T10:00:00Z"})
    {:ok, _} = Instances.record_heartbeat(instance.id, status)

    lv |> element("#rollback") |> render_click()
    assert_receive {:agent_got, "rollback", %{}}
  end

  test "logs request picks a service and tail", %{conn: conn} do
    instance = instance_fixture()
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=logs")

    lv |> form("#logs-form", %{"service" => "server", "tail" => "50"}) |> render_submit()
    assert_receive {:agent_got, "logs", %{"service" => "server", "tail" => "50"}}
  end

  test "reads the .env and saves the edited one", %{conn: conn} do
    instance = instance_fixture()
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=settings")
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
    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=settings")

    assert lv |> element("#instance-actions button", "Обновить") |> render() =~ "disabled"

    lv |> element("#delete-instance") |> render_click()
    assert_redirect(lv, ~p"/")
    assert Instances.list_instances() == []
  end

  test "backups are made and restored from the instance page", %{conn: conn} do
    Req.Test.stub(Bastion.Http, &Plug.Conn.send_resp(&1, 200, ""))
    instance = instance_fixture(%{info: %{"name" => "Pizza Backup"}})

    {:ok, done} =
      Bastion.Repo.insert(%Bastion.Backups.Backup{
        instance_id: instance.id,
        instance_name: instance.name,
        key: "x.dump",
        status: "ok",
        size: 2_097_152
      })

    bring_online(instance)
    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=backups")

    lv |> element("#backup-#{done.id} button", "Восстановить") |> render_click()
    assert_receive {:agent_got, "restore", %{"backup_id" => backup_id}}
    assert backup_id == done.id

    [command] = Instances.list_commands(instance.id)
    Instances.command_finished(instance.id, command.id, true, "restored")
    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=backups")

    lv |> element("#backup-now") |> render_click()
    assert_receive {:agent_got, "backup", %{"upload_url" => _}}
    assert has_element?(lv, "#backup-list .badge", "идёт")
  end

  test "a dump file can be uploaded and restored", %{conn: conn} do
    Req.Test.stub(Bastion.Http, &Plug.Conn.send_resp(&1, 200, ""))
    instance = instance_fixture(%{info: %{"name" => "Pizza Upload"}})
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=backups")

    dump =
      file_input(lv, "#restore-file", :dump, [
        %{name: "prod.dump", content: "PGDMP-file", type: "application/octet-stream"}
      ])

    render_upload(dump, "prod.dump")
    lv |> form("#restore-file") |> render_submit()

    assert_receive {:agent_got, "restore", %{"backup_id" => backup_id}}
    assert %{instance_id: id, status: "ok"} = Bastion.Backups.get(backup_id)
    assert id == instance.id
  end

  test "a file that is not a dump is refused", %{conn: conn} do
    instance = instance_fixture()
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=backups")

    dump = file_input(lv, "#restore-file", :dump, [%{name: "notes.txt", content: "hello"}])
    render_upload(dump, "notes.txt")

    assert lv |> form("#restore-file") |> render_submit() =~ "Файл не принят"
    refute_receive {:agent_got, "restore", _}
  end

  test "the load of the host is shown with charts for a period", %{conn: conn} do
    instance = instance_fixture()
    now = DateTime.utc_now(:second)

    for minutes <- [3, 2, 1] do
      Bastion.Metrics.record(
        instance.id,
        healthy_status()["metrics"],
        DateTime.add(now, -minutes * 60)
      )
    end

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")

    assert has_element?(lv, "#load-now", "13%")
    assert has_element?(lv, "#load-now", "4 ядер")
    assert has_element?(lv, "#load-cpu polyline")
    assert has_element?(lv, "#load-memory", "в среднем 25%")

    lv |> element("button[phx-value-period=month]") |> render_click()
    assert has_element?(lv, "button.btn-active[phx-value-period=month]")
    assert has_element?(lv, "#load-cpu polyline")
  end

  test "orders that did not reach the crm are shown on the pages", %{conn: conn} do
    instance = instance_fixture(%{info: %{"name" => "Pizza CRM"}})

    status =
      Map.put(healthy_status(), "crm", [
        %{
          "id" => "o1",
          "number" => "A017",
          "branch" => "Центр",
          "status" => "failed",
          "error" => "timeout",
          "attempts" => 7,
          "inserted_at" => "2026-10-22T07:26:43"
        }
      ])

    {:ok, _} = Instances.record_heartbeat(instance.id, status)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")
    assert has_element?(lv, "#tab-errors .badge", "1")

    lv |> element("#tab-errors") |> render_click()
    assert has_element?(lv, "#crm-order-o1", "A017")
    assert has_element?(lv, "#crm-order-o1", "не ушёл")

    {:ok, list, _html} = live(log_in(conn), ~p"/")
    assert has_element?(list, "#instance-#{instance.id}", "CRM: 1")

    lv |> element("#crm-order-o1 button", "Убрал") |> render_click()
    refute has_element?(lv, "#crm-order-o1")
    assert has_element?(lv, "#tab-errors-panel", "Ошибок нет")

    {:ok, list, _html} = live(log_in(conn), ~p"/")
    refute has_element?(list, "#instance-#{instance.id}", "CRM:")
  end
end
