defmodule Bastion.MetricsAlertsTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.{Instances, Metrics}
  alias Bastion.Metrics.Alerts

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
  end

  defp sample(instance, at, cpu, memory \\ 50) do
    available = round(8_000_000 * (100 - memory) / 100)

    Metrics.record(
      instance.id,
      %{
        "cpu_percent" => cpu,
        "memory" => %{"total_kb" => 8_000_000, "available_kb" => available}
      },
      at
    )

    Alerts.check(instance.id, at)
  end

  defp minute(start, n), do: DateTime.add(start, n * 60)

  test "cpu above 90% for 5 minutes alerts once and then reports the recovery" do
    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    start = DateTime.add(DateTime.utc_now(:second), -20 * 60)

    for n <- 0..3, do: sample(instance, minute(start, n), 95)
    refute_received {:telegram, _}

    sample(instance, minute(start, 4), 96)
    assert_received {:telegram, "🔥 Pizza: процессор загружен на 96% уже 5 минут"}
    assert %{load_alerts: %{"cpu" => _}} = Instances.get_instance(instance.id)

    sample(instance, minute(start, 5), 97)
    sample(instance, minute(start, 6), 80)
    refute_received {:telegram, _}

    sample(instance, minute(start, 7), 40)
    assert_received {:telegram, "✅ Pizza: процессор снова в норме, 40%"}
    assert %{load_alerts: %{}} = Instances.get_instance(instance.id)
  end

  test "a short spike or a gap in the samples does not alert" do
    instance = instance_fixture()
    start = DateTime.add(DateTime.utc_now(:second), -30 * 60)

    for n <- [0, 1, 2, 3, 5], do: sample(instance, minute(start, n), 99)
    sample(instance, minute(start, 6), 50)
    for n <- [10, 11, 12, 20, 21], do: sample(instance, minute(start, n), 99)

    refute_received {:telegram, _}
  end

  test "memory has its own alert" do
    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    start = DateTime.add(DateTime.utc_now(:second), -20 * 60)

    for n <- 0..4, do: sample(instance, minute(start, n), 10, 93)
    assert_received {:telegram, "🔥 Pizza: память занята на 93% уже 5 минут"}
    refute_received {:telegram, _}
  end

  test "no alerts while a command runs" do
    instance = instance_fixture()
    start = DateTime.add(DateTime.utc_now(:second), -20 * 60)

    Repo.insert!(%Bastion.Instances.Command{
      instance_id: instance.id,
      action: "update",
      status: "running"
    })

    for n <- 0..6, do: sample(instance, minute(start, n), 99)
    refute_received {:telegram, _}
  end
end
