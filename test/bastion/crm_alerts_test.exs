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

  test "a stuck order alerts, then alerts again when it fails", %{instance: instance} do
    CrmAlerts.check(instance.id, [order("pending", %{"error" => nil, "attempts" => 0})])
    assert_received {:telegram, "⏳ Pizza: заказ №A017 больше 5 минут не уходит в Frontpad" <> _}

    CrmAlerts.check(instance.id, [order("failed", %{"attempts" => 7})])
    assert_received {:telegram, "🚨 Pizza: заказ №A017 не ушёл в Frontpad" <> _}
    refute_received {:telegram, _}
  end

  test "a stuck order that leaves the queue is reported", %{instance: instance} do
    CrmAlerts.check(instance.id, [order("pending")])
    assert_received {:telegram, "⏳" <> _}

    CrmAlerts.check(instance.id, [])
    assert_received {:telegram, "✅ Pizza: заказ №A017 больше не ждёт отправки в Frontpad"}
    assert %{crm_alerts: alerts} = Instances.get_instance(instance.id)
    assert alerts == %{}
  end

  test "a missing report from an old agent changes nothing", %{instance: instance} do
    CrmAlerts.check(instance.id, [order("failed")])
    assert_received {:telegram, _}

    assert :skipped = CrmAlerts.check(instance.id, nil)
    assert %{crm_alerts: %{"order-1" => _}} = Instances.get_instance(instance.id)
  end
end
