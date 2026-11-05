defmodule Bastion.MaintenanceTest do
  use Bastion.DataCase, async: true

  import Bastion.Fixtures

  alias Bastion.{Downtime, Maintenance}
  alias Bastion.Instances

  @start ~U[2026-10-21 10:00:00Z]

  test "start is idempotent, closes an old incident, and preserves actual stopped state" do
    instance = instance_fixture()

    instance =
      instance
      |> Ecto.Changeset.change(stopped_at: DateTime.add(@start, -60), down_since: @start)
      |> Repo.update!()

    {:opened, _} =
      Downtime.track(instance, %{level: :down, problems: ["failed"]}, DateTime.add(@start, -120))

    assert {:error, :invalid_duration} = Maintenance.start(instance, 14, @start)
    assert {:ok, started} = Maintenance.start(instance, 30, @start)
    assert started.maintenance_until == DateTime.add(@start, 1800)
    assert started.stopped_at == instance.stopped_at
    assert started.down_since == nil
    assert Downtime.open_incident(instance.id) == nil

    assert {:ok, again} = Maintenance.start(instance, 60, DateTime.add(@start, 60))
    assert again.maintenance_until == started.maintenance_until
    assert [%{started_at: @start}] = Maintenance.windows(instance)
    assert Maintenance.active?(again, DateTime.add(@start, 1799))
    refute Maintenance.active?(again, DateTime.add(@start, 1800))
  end

  test "finish ends history early and preserves service state" do
    instance = instance_fixture()
    {:ok, started} = Maintenance.start(instance, 30, @start)
    finish_at = DateTime.add(@start, 600)

    assert {:ok, finished} = Maintenance.finish(started, finish_at)
    assert finished.maintenance_until == nil
    assert finished.stopped_at == instance.stopped_at
    assert [%{ended_at: ^finish_at}] = Maintenance.windows(instance)

    assert Maintenance.intervals(instance.id, @start, DateTime.add(@start, 3600)) == [
             {@start, finish_at}
           ]

    assert {:ok, _} = Maintenance.finish(finished, DateTime.add(@start, 1200))
    assert length(Maintenance.windows(instance)) == 1
  end

  test "expired windows and overlapping history are clamped and merged" do
    instance = instance_fixture()
    {:ok, _} = Maintenance.start(instance, 30, @start)
    {:ok, _} = Maintenance.start(instance, 30, DateTime.add(@start, 900))

    Repo.insert!(%Bastion.Maintenance.Window{
      instance_id: instance.id,
      started_at: DateTime.add(@start, 1200),
      scheduled_end_at: DateTime.add(@start, 2700)
    })

    assert Maintenance.intervals(
             instance.id,
             DateTime.add(@start, 600),
             DateTime.add(@start, 2400)
           ) == [{DateTime.add(@start, 600), DateTime.add(@start, 2400)}]
  end

  test "starting broadcasts instance update" do
    instance = instance_fixture()
    Instances.subscribe()
    assert {:ok, updated} = Maintenance.start(instance, 15, @start)
    id = updated.id
    assert_receive {:instance_updated, %{id: ^id}}
  end
end
