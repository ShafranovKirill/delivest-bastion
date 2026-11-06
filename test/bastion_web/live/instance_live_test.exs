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
    assert has_element?(lv, "h1", "Франшизы")
    assert has_element?(lv, "#instances thead th", "Админка")
    assert has_element?(lv, "#instances thead th", "Сайт")

    assert has_element?(
             lv,
             "#instances tbody[phx-update='stream'] #instance-#{instance.id} > td:nth-child(4)",
             "Админка"
           )

    assert has_element?(
             lv,
             "#instances tbody[phx-update='stream'] #instance-#{instance.id} > td:nth-child(5)",
             "Сайт"
           )

    assert has_element?(lv, "#instance-#{instance.id} > td:first-child a", "Pizza North")

    assert has_element?(
             lv,
             "#server-open-#{instance.id}[href='https://api.example.com/staff'][target='_blank'][rel='noopener noreferrer']"
           )

    assert has_element?(lv, "#client-open-#{instance.id}[href='https://site.example.com/']")
    refute has_element?(lv, "#instances thead th", "Диск")
    refute has_element?(lv, "#instances thead th", "Аптайм 7 дн")

    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    refute has_element?(lv, "#problem-#{instance.id}")
    refute has_element?(lv, "#instances thead th", "Состояние")
  end

  test "opens validated server and client URLs and mutes unsafe hosts", %{conn: conn} do
    good =
      instance_fixture(%{
        info: %{
          "hosts" => %{
            "api" => "http://localhost:4000/api",
            "site" => "http://localhost:3000/shop"
          }
        }
      })

    unsafe =
      instance_fixture(%{
        info: %{
          "hosts" => %{
            "api" => "javascript:alert(1)",
            "site" => "https://user:secret@example.com"
          }
        }
      })

    blank = instance_fixture(%{info: %{"hosts" => %{"api" => nil, "site" => ""}}})

    malformed =
      instance_fixture(%{
        info: %{
          "hosts" => %{"api" => "https://example.com:bad", "site" => "https://example.com:999999"}
        }
      })

    {:ok, list, _} = live(log_in(conn), ~p"/")
    assert has_element?(list, "#server-open-#{good.id}[href='http://localhost:4000/staff']")
    assert has_element?(list, "#client-open-#{good.id}[href='http://localhost:3000/shop']")
    assert has_element?(list, "span#server-open-#{unsafe.id}", "Не настроен")
    assert has_element?(list, "span#client-open-#{unsafe.id}", "Не настроен")
    assert has_element?(list, "span#server-open-#{blank.id}", "Не настроен")
    assert has_element?(list, "span#client-open-#{blank.id}", "Не настроен")
    assert has_element?(list, "span#server-open-#{malformed.id}", "Не настроен")
    assert has_element?(list, "span#client-open-#{malformed.id}", "Не настроен")

    {:ok, detail, _} = live(log_in(build_conn()), ~p"/instances/#{unsafe.id}")
    assert has_element?(detail, "span#detail-server-open", "Не настроен")
    assert has_element?(detail, "span#detail-client-open", "Не настроен")
  end

  test "problematic instances come first without showing problem details in the list", %{
    conn: conn
  } do
    healthy = instance_fixture(%{info: %{"name" => "Healthy"}})
    broken = instance_fixture(%{info: %{"name" => "Broken"}})
    {:ok, _} = Instances.record_heartbeat(healthy.id, healthy_status())

    failing =
      put_in(healthy_status(), ["checks", "api"], %{"ok" => false, "error" => "secret failure"})

    {:ok, _} = Instances.record_heartbeat(broken.id, failing)

    {:ok, list, _} = live(log_in(conn), ~p"/")
    assert has_element?(list, "#instances tbody tr:first-child[id='instance-#{broken.id}']")
    assert has_element?(list, "#problem-#{broken.id}", "Ошибки")
    refute has_element?(list, "#instance-#{broken.id}", "secret failure")
  end

  test "sends commands to an online agent", %{conn: conn} do
    instance = instance_fixture()
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")
    assert has_element?(lv, "#technical-details:not([open]) #containers", "server")
    assert has_element?(lv, "#tab-state-panel > #uptime:first-child")
    assert has_element?(lv, "#tab-state-panel > #load:nth-child(2)")
    refute has_element?(lv, "#instance-start")
    refute has_element?(lv, "#instance-restart")

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

    lv |> element("#tab-history") |> render_click()
    lv |> element("#rollback") |> render_click()
    assert_receive {:agent_got, "rollback", %{}}
  end

  test "an undated rollback does not break the instance page", %{conn: conn} do
    instance = instance_fixture()
    status = Map.put(healthy_status(), "rollback", %{"at" => nil, "previous" => %{}})
    {:ok, _} = Instances.record_heartbeat(instance.id, status)
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=history")
    assert has_element?(lv, "#rollback")
  end

  test "orders, errors, the database and site alerts are shown", %{conn: conn} do
    instance = instance_fixture()

    status =
      Map.merge(healthy_status(), %{
        "orders" => %{"last_hour" => 0, "usual" => 9},
        "errors" => %{
          "last_5m" => 30,
          "last_hour" => 41,
          "latest" => [%{"message" => "boom", "inserted_at" => "2026-10-23T10:00:00.123"}]
        },
        "database" => %{"size_bytes" => 5_242_880},
        "env" => %{"missing" => ["NEW_KEY"]}
      })

    previous = Instances.get_instance(instance.id)
    {:ok, _} = Instances.record_heartbeat(instance.id, status)
    Bastion.SiteAlerts.check(previous, status)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}")
    assert has_element?(lv, "#app-stats", "5.0 МБ")
    assert has_element?(lv, "#tab-state-panel > #uptime:first-child")
    assert has_element?(lv, "#tab-state-panel > #app-stats:nth-child(2)")
    assert has_element?(lv, "#tab-state-panel > #load:nth-child(3)")

    assert has_element?(
             lv,
             "#tab-state-panel > #technical-details:last-child:not([open]) #checks"
           )

    refute has_element?(lv, "#latest-errors")

    lv |> element("#tab-errors") |> render_click()
    assert has_element?(lv, "#latest-errors", "boom")
    assert has_element?(lv, "#site-alert-orders")
    assert has_element?(lv, "#site-alert-errors")

    lv |> element("#tab-settings") |> render_click()
    assert has_element?(lv, "#env-missing", "NEW_KEY")

    {:ok, index, _html} = live(log_in(build_conn()), ~p"/")
    assert has_element?(index, "#instance-#{instance.id}", "Предупреждения")
    refute has_element?(index, "#instance-#{instance.id}", "Нет заказов")
  end

  test "the agent updates itself from the settings tab", %{conn: conn} do
    instance = instance_fixture()
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    bring_online(instance)

    {:ok, lv, _html} = live(log_in(conn), ~p"/instances/#{instance.id}?tab=settings")
    lv |> element("#agent-update") |> render_click()
    assert_receive {:agent_got, "agent_update", %{}}
  end

  test "maintenance starts and finishes from the instance page", %{conn: conn} do
    instance = instance_fixture()
    {:ok, lv, _} = live(log_in(conn), ~p"/instances/#{instance.id}")
    refute has_element?(lv, "#instance-stop")
    refute has_element?(lv, "#maintenance-form")

    lv |> element("#maintenance-open") |> render_click()
    assert has_element?(lv, "#maintenance-form select", "30 минут")
    lv |> form("#maintenance-form", %{"minutes" => "15"}) |> render_submit()
    assert has_element?(lv, "#maintenance-active", "Обслуживание до")
    refute has_element?(lv, "#maintenance-form")

    lv |> element("#maintenance-finish") |> render_click()
    refute has_element?(lv, "#maintenance-active")
    lv |> element("#tab-history") |> render_click()
    assert has_element?(lv, "#maintenance-history [id^=maintenance-window-]")

    lv |> element("#tab-settings") |> render_click()
    assert has_element?(lv, "#danger-zone #instance-stop")
    assert has_element?(lv, "#instance-management #instance-restart")
  end

  test "offers start only when the site or its app container is stopped", %{conn: conn} do
    instance = instance_fixture()
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())
    bring_online(instance)

    {:ok, lv, _} = live(log_in(conn), ~p"/instances/#{instance.id}")
    refute has_element?(lv, "#instance-start")

    stopped = put_in(healthy_status(), ["containers", Access.at(0), "state"], "exited")
    {:ok, _} = Instances.record_heartbeat(instance.id, stopped)
    assert has_element?(lv, "#instance-start")
  end

  test "shows the latest completed update and restore in the detail history", %{conn: conn} do
    instance = instance_fixture()
    now = DateTime.utc_now(:second)

    for action <- ["update", "restore"] do
      Bastion.Repo.insert!(%Bastion.Instances.Command{
        instance_id: instance.id,
        action: action,
        status: "ok",
        finished_at: now
      })
    end

    {:ok, lv, _} = live(log_in(conn), ~p"/instances/#{instance.id}")
    timestamp = Calendar.strftime(now, "%d.%m.%Y %H:%M:%S UTC")

    refute has_element?(lv, "#recent-operations")
    assert has_element?(lv, "#instance-tools:not([open])")

    lv |> element("#tab-history") |> render_click()

    assert has_element?(
             lv,
             "#tab-history-panel",
             "Восстановление бэкапа через Bastion: #{timestamp}"
           )
  end

  test "the list keeps actions inside each franchise and shows a completed image check", %{
    conn: conn
  } do
    instance_fixture()
    {:ok, lv, _html} = live(log_in(conn), ~p"/")
    refute has_element?(lv, "#rollout-start")
    refute has_element?(lv, "#instances thead th", "Действия")
    lv |> element("#check-images") |> render_click()
    render_async(lv)
    assert has_element?(lv, "#image-check-result", "Проверено образов: 0. Ошибок: 0.")
    refute has_element?(lv, "#check-images[disabled]")
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
    refute has_element?(lv, "#tab-errors .badge")

    lv |> element("#tab-errors") |> render_click()
    assert has_element?(lv, "#errors-summary .badge", "1")
    assert has_element?(lv, "#crm-order-o1", "A017")
    assert has_element?(lv, "#crm-order-o1", "не ушёл")

    {:ok, list, _html} = live(log_in(conn), ~p"/")
    refute has_element?(list, "#instance-#{instance.id}", "CRM: 1")

    lv |> element("#crm-order-o1 button", "Убрал") |> render_click()
    refute has_element?(lv, "#crm-order-o1")
    assert has_element?(lv, "#tab-errors-panel", "Ошибок нет")

    {:ok, list, _html} = live(log_in(conn), ~p"/")
    refute has_element?(list, "#instance-#{instance.id}", "CRM:")
  end

  test "client details and encrypted credentials persist without exposing the password", %{
    conn: conn
  } do
    instance = instance_fixture()
    {:ok, lv, _} = live(log_in(conn), ~p"/instances/#{instance.id}")
    assert has_element?(lv, "#instance-tools:not([open])")
    refute has_element?(lv, "#instance-actions #instance-backup")
    refute has_element?(lv, "#instance-actions #maintenance-open")
    lv |> element("#edit-client") |> render_click()
    due_on = Date.add(Bastion.PaymentReminderWorker.today(), 5)

    lv
    |> form("#client-form",
      client: %{
        contact_phone: "+7 900 123-45-67",
        social_links: "https://t.me/client",
        payment_due_on: Date.to_iso8601(due_on),
        admin_login: "owner",
        admin_password: "private-pass-123"
      }
    )
    |> render_submit()

    assert has_element?(lv, "#client-contact", "+7 900 123-45-67")
    assert has_element?(lv, "#client-contact a[href='https://t.me/client']")
    assert has_element?(lv, "#saved-password", "••••••••")
    refute has_element?(lv, "#admin-credentials", "private-pass-123")
    stored = Instances.get_instance(instance.id)
    assert stored.admin_password_encrypted != "private-pass-123"
    assert stored.admin_password == nil

    assert {:ok, "private-pass-123"} =
             Bastion.Credentials.decrypt(stored.admin_password_encrypted)

    lv |> element("#toggle-password") |> render_click()
    assert has_element?(lv, "#saved-password", "private-pass-123")
    lv |> element("#toggle-password") |> render_click()
    refute has_element?(lv, "#saved-password", "private-pass-123")
    lv |> element("#edit-client") |> render_click()

    lv
    |> form("#client-form", client: %{contact_phone: "+7 900 999-99-99", admin_password: ""})
    |> render_submit()

    assert Instances.get_instance(instance.id).admin_password_encrypted ==
             stored.admin_password_encrypted

    {:ok, list, _} = live(log_in(build_conn()), ~p"/")

    assert has_element?(
             list,
             "#subscription-#{instance.id}",
             Calendar.strftime(due_on, "%d.%m.%Y")
           )

    assert has_element?(list, "#subscription-#{instance.id}", "Осталось 5 дн.")
  end

  test "invalid contacts and dates cannot replace saved client data", %{conn: conn} do
    instance = instance_fixture()
    {:ok, lv, _} = live(log_in(conn), ~p"/instances/#{instance.id}")
    lv |> element("#edit-client") |> render_click()

    lv
    |> form("#client-form",
      client: %{
        social_links: "javascript:alert(1)",
        payment_due_on: "bad-date",
        admin_password: "do-not-echo"
      }
    )
    |> render_submit()

    assert has_element?(lv, "#client-form")
    refute has_element?(lv, "#client-form input[value='do-not-echo']")
    assert Instances.get_instance(instance.id).social_links == nil
    assert Instances.get_instance(instance.id).admin_password_encrypted == nil
  end

  test "versions show the installed release and available update in the list", %{conn: conn} do
    instance = instance_fixture()
    image = "ghcr.io/test/ui-version:latest"
    Bastion.Images.put(image, "new", "2.0.0")

    status =
      put_in(healthy_status(), ["containers"], [
        %{
          "service" => "server",
          "state" => "running",
          "revision" => "old",
          "image" => image,
          "version" => "1.0.0"
        }
      ])

    Instances.record_heartbeat(instance.id, status)
    {:ok, lv, _} = live(log_in(conn), ~p"/")
    assert has_element?(lv, "#version-#{instance.id}", "1.0.0")
    assert has_element?(lv, "#version-#{instance.id}", "2.0.0")
    assert has_element?(lv, "#version-#{instance.id}", "Есть обновление")
  end
end
