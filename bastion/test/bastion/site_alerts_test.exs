defmodule Bastion.SiteAlertsTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.{Instances, Repo, SiteAlerts}
  alias Bastion.Instances.Instance

  setup do
    Application.put_env(:bastion, :telegram_bot_token, "bot")
    Application.put_env(:bastion, :telegram_chat_id, "42")
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:telegram, Jason.decode!(body)["text"]})
      Req.Test.json(conn, %{"ok" => true})
    end)

    on_exit(fn ->
      Application.delete_env(:bastion, :telegram_chat_id)
      Application.put_env(:bastion, :telegram_bot_token, nil)
    end)

    %{instance: instance_fixture(%{info: %{"name" => "Pizza"}})}
  end

  # The heartbeat as the channel handles it: alerts compare with the previous one.
  defp heartbeat(instance, status) do
    previous = Repo.get!(Instance, instance.id)
    {:ok, _} = Instances.record_heartbeat(instance.id, status)
    SiteAlerts.check(previous, status)
    Repo.get!(Instance, instance.id)
  end

  defp status(extra), do: Map.merge(healthy_status(), extra)

  test "no orders in an hour when they usually come alerts once until they come back", %{
    instance: instance
  } do
    quiet = status(%{"orders" => %{"last_hour" => 0, "usual" => 7.5}})

    assert %{site_alerts: %{"orders" => _}} = heartbeat(instance, quiet)
    assert_received {:telegram, text}
    assert text =~ "Pizza: за последний час ни одного заказа, а обычно в это время около 7.5"

    heartbeat(instance, quiet)
    refute_received {:telegram, _}

    assert %{site_alerts: alerts} =
             heartbeat(instance, status(%{"orders" => %{"last_hour" => 2, "usual" => 7.5}}))

    assert alerts == %{}
    assert_received {:telegram, "✅ Pizza: заказы снова идут, за последний час 2"}
  end

  test "a quiet hour is fine when orders rarely come at that time", %{instance: instance} do
    assert %{site_alerts: alerts} =
             heartbeat(instance, status(%{"orders" => %{"last_hour" => 0, "usual" => 1.0}}))

    assert alerts == %{}
    refute_received {:telegram, _}
  end

  test "a burst of application errors alerts with the latest message", %{instance: instance} do
    errors = %{"last_5m" => 25, "latest" => [%{"message" => "Frontpad timeout"}]}

    assert %{site_alerts: %{"errors" => %{"count" => 25}}} =
             heartbeat(instance, status(%{"errors" => errors}))

    assert_received {:telegram, text}
    assert text =~ "25 ошибок в приложении за 5 минут\nПоследняя: Frontpad timeout"

    heartbeat(instance, status(%{"errors" => %{"last_5m" => 10}}))
    refute_received {:telegram, _}

    heartbeat(instance, status(%{"errors" => %{"last_5m" => 1}}))
    assert_received {:telegram, "✅ Pizza: ошибок стало меньше, 1 за 5 минут"}
  end

  test "a container restarted by docker is reported once in half an hour", %{instance: instance} do
    containers = fn restarts ->
      [%{"service" => "server", "state" => "running", "restarts" => restarts}]
    end

    heartbeat(instance, status(%{"containers" => containers.(0)}))

    assert %{site_alerts: %{"crash:server" => %{"restarts" => 1}}} =
             heartbeat(instance, status(%{"containers" => containers.(1)}))

    assert_received {:telegram, text}
    assert text =~ "контейнер server упал и перезапустился (всего 1 раз)"

    heartbeat(instance, status(%{"containers" => containers.(2)}))
    refute_received {:telegram, _}

    # A recreated container starts from zero, which is not a crash.
    heartbeat(instance, status(%{"containers" => containers.(0)}))
    refute_received {:telegram, _}
  end

  test "an almost full disk alerts with the free space and the database size", %{
    instance: instance
  } do
    full =
      status(%{
        "disk" => %{"total_kb" => 100_000_000, "used_kb" => 96_000_000, "free_kb" => 4_000_000},
        "database" => %{"size_bytes" => 2_147_483_648}
      })

    assert %{site_alerts: %{"disk" => %{"percent" => 96}}} = heartbeat(instance, full)
    assert_received {:telegram, text}
    assert text =~ "диск заполнен на 96%, свободно 3.8 ГБ. База занимает 2.0 ГБ."

    heartbeat(instance, status(%{}))
    assert_received {:telegram, "✅ Pizza: место на диске освободилось, занято 40%"}
  end

  test "a site stopped on purpose raises nothing", %{instance: instance} do
    instance |> Ecto.Changeset.change(stopped_at: DateTime.utc_now(:second)) |> Repo.update!()

    assert %{site_alerts: alerts} =
             heartbeat(instance, status(%{"orders" => %{"last_hour" => 0, "usual" => 10}}))

    assert alerts == %{}
  end
end
