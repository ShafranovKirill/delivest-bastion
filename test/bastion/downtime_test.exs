defmodule Bastion.DowntimeTest do
  use Bastion.DataCase, async: true

  import Bastion.Fixtures

  alias Bastion.Downtime

  @now ~U[2026-10-21 12:00:00Z]

  defp instance(inserted_at \\ ~U[2026-09-01 00:00:00Z]) do
    instance = instance_fixture()

    instance
    |> Ecto.Changeset.change(inserted_at: inserted_at)
    |> Repo.update!()
  end

  test "an incident opens on errors and closes when the site is back" do
    instance = instance()
    down = %{level: :down, problems: ["API не отвечает снаружи (HTTP 502)"]}

    assert {:opened, incident} = Downtime.track(instance, down, ~U[2026-10-21 11:00:00Z])
    assert incident.problems == down.problems
    assert :none = Downtime.track(instance, %{down | level: :offline}, ~U[2026-10-21 11:05:00Z])

    assert {:closed, closed} =
             Downtime.track(instance, %{level: :ok, problems: []}, ~U[2026-10-21 11:30:00Z])

    assert closed.id == incident.id
    assert Downtime.duration(closed) == 1800
    assert :none = Downtime.track(instance, %{level: :warning, problems: ["диск"]}, @now)
  end

  test "a planned stop closes the incident and is not downtime" do
    instance = instance()
    {:opened, _} = Downtime.track(instance, %{level: :down, problems: []}, @now)
    assert {:closed, _} = Downtime.track(instance, %{level: :stopped, problems: []}, @now)
    assert :none = Downtime.track(instance, %{level: :stopped, problems: []}, @now)
  end

  test "summary counts only the part of incidents inside each period" do
    instance = instance()

    Repo.insert!(%Downtime.Incident{
      instance_id: instance.id,
      level: "down",
      started_at: ~U[2026-10-20 11:00:00Z],
      ended_at: ~U[2026-10-20 13:00:00Z]
    })

    Repo.insert!(%Downtime.Incident{
      instance_id: instance.id,
      level: "offline",
      started_at: ~U[2026-10-21 11:54:00Z]
    })

    summary = Downtime.summary(instance, @now)

    assert summary.day.down_seconds == 3600 + 360
    assert summary.week.down_seconds == 7200 + 360
    assert summary.day.uptime == 95.42
  end

  test "a young instance is measured from its registration" do
    instance = instance(~U[2026-10-21 10:00:00Z])

    Repo.insert!(%Downtime.Incident{
      instance_id: instance.id,
      level: "down",
      started_at: ~U[2026-10-21 11:00:00Z],
      ended_at: ~U[2026-10-21 11:12:00Z]
    })

    assert %{down_seconds: 720, uptime: 90.0} = Downtime.summary(instance, @now).month
  end

  test "durations read naturally" do
    assert Downtime.format_duration(42) == "42 с"
    assert Downtime.format_duration(600) == "10 мин"
    assert Downtime.format_duration(3600) == "1 ч"
    assert Downtime.format_duration(3 * 3600 + 5 * 60) == "3 ч 5 мин"
    assert Downtime.format_duration(2 * 86_400 + 4 * 3600) == "2 дн 4 ч"
  end
end
