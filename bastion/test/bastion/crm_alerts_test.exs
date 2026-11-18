defmodule Bastion.CrmAlertsTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.{CrmAlerts, Instances}

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

  defp order(status, attrs \\ %{}) do
    Map.merge(
      %{
        "id" => "order-1",
        "number" => "A017",
        "branch" => "Центр",
        "provider" => "frontpad",
        "status" => status,
        "error" => ~s({:frontpad, "invalid_product_keys"}),
        "attempts" => 1,
        "inserted_at" => NaiveDateTime.to_iso8601(NaiveDateTime.utc_now(:second))
      },
      attrs
    )
  end

  test "a failed order alerts once with what to do", %{instance: instance} do
    CrmAlerts.check(instance.id, [order("failed")])

    assert_received {:telegram, text}
    assert text =~ "🚨 Pizza: заказ №A017 не ушёл в Frontpad"
    assert text =~ "Филиал: Центр"
    assert text =~ "invalid_product_keys"
    assert text =~ "Передайте заказ вручную."

    CrmAlerts.check(instance.id, [order("failed")])
    refute_received {:telegram, _}
  end

  test "a stuck order stays silent until it fails", %{instance: instance} do
    CrmAlerts.check(instance.id, [order("pending", %{"error" => nil, "attempts" => 0})])
    refute_received {:telegram, _}

    CrmAlerts.check(instance.id, [order("failed", %{"attempts" => 7})])
    assert_received {:telegram, "🚨 Pizza: заказ №A017 не ушёл в Frontpad" <> _}

    CrmAlerts.check(instance.id, [])
    refute_received {:telegram, _}
    assert %{crm_alerts: alerts} = Instances.get_instance(instance.id)
    assert alerts == %{}
  end

  test "a dismissed order is hidden and does not alert", %{instance: instance} do
    Instances.record_heartbeat(instance.id, %{"crm" => [order("pending")]})
    instance = Instances.get_instance(instance.id)
    assert [_] = CrmAlerts.problems(instance)

    assert {:ok, instance} = CrmAlerts.dismiss(instance, "order-1")
    assert CrmAlerts.problems(instance) == []

    CrmAlerts.check(instance.id, [order("failed")])
    refute_received {:telegram, _}
  end

  test "dismissals of orders the agent no longer reports are dropped", %{instance: instance} do
    Instances.record_heartbeat(instance.id, %{"crm" => [order("failed")]})
    {:ok, _} = instance.id |> Instances.get_instance() |> CrmAlerts.dismiss("order-1")

    Instances.record_heartbeat(instance.id, %{"crm" => [order("failed", %{"id" => "order-2"})]})
    instance = Instances.get_instance(instance.id)
    assert {:ok, %{crm_dismissed: ["order-2"]}} = CrmAlerts.dismiss(instance, "order-2")
  end

  test "a missing report from an old agent changes nothing", %{instance: instance} do
    CrmAlerts.check(instance.id, [order("failed")])
    assert_received {:telegram, _}

    assert :skipped = CrmAlerts.check(instance.id, nil)
    assert %{crm_alerts: %{"order-1" => _}} = Instances.get_instance(instance.id)
  end
end
