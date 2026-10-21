defmodule Bastion.InstancesTest do
  use Bastion.DataCase, async: true

  import Bastion.Fixtures

  alias Bastion.Instances

  test "register creates the instance once and refreshes its info" do
    instance = instance_fixture(%{info: %{"name" => "First"}})

    assert {:ok, updated} =
             Instances.register(instance.id, %{"name" => "Renamed", "agent_version" => "0.2.0"})

    assert updated.id == instance.id
    assert updated.name == "Renamed"
    assert [%{name: "Renamed"}] = Instances.list_instances()
  end

  test "heartbeats store the last status" do
    instance = instance_fixture()

    assert {:ok, %{status: %{"disk" => _}}} =
             Instances.record_heartbeat(instance.id, healthy_status())

    assert {:error, :not_found} = Instances.record_heartbeat(Ecto.UUID.generate(), %{})
  end

  test "commands need an online agent and a known action" do
    instance = instance_fixture()

    assert {:error, :offline} = Instances.send_command(instance, "update")
    assert {:error, :unknown_action} = Instances.send_command(instance, "rm")
  end

  test "command results are stored only for their own instance" do
    instance = instance_fixture()
    other = instance_fixture()

    command =
      Repo.insert!(%Bastion.Instances.Command{
        instance_id: instance.id,
        action: "logs",
        status: "sent"
      })

    assert {:error, :not_found} = Instances.command_started(other.id, command.id)
    assert {:ok, %{status: "running"}} = Instances.command_started(instance.id, command.id)

    assert {:ok, %{status: "ok", output: "{\n  \"a\": 1\n}"}} =
             Instances.command_finished(instance.id, command.id, true, %{"a" => 1})

    assert [%{id: id}] = Instances.list_commands(instance.id)
    assert id == command.id
  end

  test "deleting an instance removes its commands" do
    instance = instance_fixture()

    Repo.insert!(%Bastion.Instances.Command{
      instance_id: instance.id,
      action: "stop",
      status: "ok"
    })

    assert {:ok, _} = Instances.delete_instance(instance)
    assert Instances.list_instances() == []
    assert Repo.aggregate(Bastion.Instances.Command, :count) == 0
  end
end
