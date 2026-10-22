defmodule Bastion.MetricsTest do
  use Bastion.DataCase, async: true

  import Bastion.Fixtures

  alias Bastion.Metrics
  alias Bastion.Metrics.Sample

  defp metrics(cpu, available_kb \\ 6_000_000) do
    %{
      "cpu_percent" => cpu,
      "cpus" => 4,
      "load" => [1.5, 1.0, 0.5],
      "memory" => %{"total_kb" => 8_000_000, "available_kb" => available_kb}
    }
  end

  test "a heartbeat becomes a sample at most once a minute" do
    instance = instance_fixture()
    now = ~U[2026-10-22 10:00:00Z]

    assert {:ok, sample} = Metrics.record(instance.id, metrics(12.5), now)
    assert %{cpu: 12.5, memory: 25.0, memory_used_kb: 2_000_000, load: 1.5, cpus: 4} = sample

    assert :skipped = Metrics.record(instance.id, metrics(50), DateTime.add(now, 30))
    assert {:ok, _} = Metrics.record(instance.id, metrics(50), DateTime.add(now, 60))
    assert :skipped = Metrics.record(instance.id, nil, DateTime.add(now, 120))
    assert :skipped = Metrics.record(instance.id, %{"cpu_percent" => nil}, DateTime.add(now, 180))

    assert Repo.aggregate(Sample, :count) == 2
  end

  test "series average the samples into buckets of the period" do
    instance = instance_fixture()
    now = ~U[2026-10-22 10:00:00Z]

    for {minute, cpu} <- [{1, 10.0}, {2, 30.0}, {8, 90.0}] do
      Metrics.record(instance.id, metrics(cpu), DateTime.add(now, -60 * 60 + minute * 60))
    end

    assert %{points: [first, second]} = Metrics.series(instance.id, :day, now)
    assert first.cpu == 20.0
    assert second.cpu == 90.0
    assert %DateTime{} = first.at
  end

  test "samples older than the kept days are removed" do
    instance = instance_fixture()
    now = ~U[2026-10-22 10:00:00Z]

    Metrics.record(instance.id, metrics(10), DateTime.add(now, -31 * 86_400))
    Metrics.record(instance.id, metrics(10), DateTime.add(now, -29 * 86_400))

    assert Metrics.prune(now) == 1
    assert Repo.aggregate(Sample, :count) == 1
  end
end
