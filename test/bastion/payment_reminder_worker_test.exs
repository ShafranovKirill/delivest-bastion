defmodule Bastion.PaymentReminderWorkerTest do
  use Bastion.DataCase, async: false
  import Bastion.Fixtures
  alias Bastion.{Instances, PaymentReminderWorker, PaymentReminder, Repo}

  setup do
    previous = Application.get_env(:bastion, :telegram_bot_token)
    chat = Application.get_env(:bastion, :telegram_chat_id)
    Application.put_env(:bastion, :telegram_bot_token, "test-token")
    Application.put_env(:bastion, :telegram_chat_id, "123")

    on_exit(fn ->
      Application.put_env(:bastion, :telegram_bot_token, previous)
      Application.put_env(:bastion, :telegram_chat_id, chat)
    end)

    :ok
  end

  test "only today's payment gets one reminder, including after repeated runs and date edits" do
    due = instance_fixture()
    future = instance_fixture()
    overdue = instance_fixture()
    Instances.update_client(due, %{payment_due_on: ~D[2026-11-06]})
    Instances.update_client(future, %{payment_due_on: ~D[2026-11-07]})
    Instances.update_client(overdue, %{payment_due_on: ~D[2026-11-05]})
    owner = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(owner, {:telegram, Jason.decode!(body)})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(%{ok: true, result: %{message_id: 1}}))
    end)

    assert :ok = PaymentReminderWorker.deliver_due(~U[2026-11-06 05:59:00Z])
    refute_receive {:telegram, _}
    assert :ok = PaymentReminderWorker.deliver_due(~U[2026-11-06 06:00:00Z])
    assert_receive {:telegram, %{"text" => text, "chat_id" => "123"}}
    assert text == "Франшиза «#{due.name}» должна сегодня оплатить подписку."
    assert :ok = PaymentReminderWorker.deliver_due(~U[2026-11-06 07:00:00Z])
    Instances.update_client(Instances.get_instance(due.id), %{payment_due_on: ~D[2026-11-07]})
    Instances.update_client(Instances.get_instance(due.id), %{payment_due_on: ~D[2026-11-06]})
    assert :ok = PaymentReminderWorker.deliver_due(~U[2026-11-06 08:00:00Z])
    refute_receive {:telegram, _}
    assert [%PaymentReminder{instance_id: id, due_on: ~D[2026-11-06]}] = Repo.all(PaymentReminder)
    assert id == due.id
  end

  test "Telegram failures are not marked delivered and can be retried" do
    due = instance_fixture()
    Instances.update_client(due, %{payment_due_on: ~D[2026-11-06]})

    Req.Test.stub(
      Bastion.Http,
      &(&1
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(400, Jason.encode!(%{description: "bad request"})))
    )

    assert {:error, "bad request"} = PaymentReminderWorker.deliver_due(~U[2026-11-06 06:00:00Z])
    assert Repo.all(PaymentReminder) == []

    Req.Test.stub(
      Bastion.Http,
      &(&1
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(200, Jason.encode!(%{ok: true, result: %{message_id: 1}})))
    )

    assert :ok = PaymentReminderWorker.deliver_due(~U[2026-11-06 06:05:00Z])
    assert Repo.aggregate(PaymentReminder, :count) == 1
  end

  test "the Moscow date boundary does not send an overdue reminder" do
    instance = instance_fixture()
    Instances.update_client(instance, %{payment_due_on: ~D[2026-11-06]})
    assert :ok = PaymentReminderWorker.deliver_due(~U[2026-11-06 21:00:00Z])
    assert Repo.all(PaymentReminder) == []
  end
end
