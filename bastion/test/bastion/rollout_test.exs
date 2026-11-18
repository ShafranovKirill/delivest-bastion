defmodule Bastion.RolloutTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.{Images, Instances, Repo, Rollout}
  alias BastionWeb.Presence

  setup do
    Rollout.cancel("test")
    on_exit(fn -> Rollout.cancel("test") end)
    :ok
  end

  defp bring_online(instance) do
    test_pid = self()

    spawn_link(fn ->
      Instances.subscribe_commands(instance.id)
      {:ok, _} = Presence.track_agent(self(), instance.id)
      send(test_pid, :online)

      loop = fn loop ->
        receive do
          {:push_command, command} -> send(test_pid, {:agent_got, instance.id, command})
        end

        loop.(loop)
      end

      loop.(loop)
    end)

    assert_receive :online
    Instances.get_instance(instance.id)
  end

  defp behind(name) do
    image = "ghcr.io/test/rollout-#{System.unique_integer([:positive])}:latest"
    Images.put(image, "new")

    instance =
      instance_fixture(%{
        info: %{"name" => name, "actions" => Instances.actions() -- ["rollback"]}
      })

    status =
      Map.put(healthy_status(), "containers", [
        %{"service" => "server", "state" => "running", "image" => image, "revision" => "old"}
      ])

    {:ok, _} = Instances.record_heartbeat(instance.id, status)
    bring_online(instance)
  end

  defp checked_now(instance) do
    instance
    |> Ecto.Changeset.change(
      checked_at: DateTime.add(DateTime.utc_now(:second), 5),
      external: %{"api" => %{"ok" => true, "status" => 200}}
    )
    |> Repo.update!()
  end

  defp wait_for(fun) do
    Enum.reduce_while(1..100, nil, fn _, _ ->
      state = Rollout.state()
      if fun.(state), do: {:halt, state}, else: Process.sleep(10) && {:cont, nil}
    end) || flunk("rollout did not reach the expected state: #{inspect(Rollout.state())}")
  end

  test "sites are updated one after another once the previous one answers" do
    first = behind("A first")
    second = behind("B second")

    assert :ok = Rollout.start("admin")
    assert_receive {:agent_got, id, %{action: "update"} = command}
    assert id == first.id
    refute_receive {:agent_got, _, _}, 50

    Instances.command_finished(first.id, command.id, true, "ok")
    checked_now(first)

    assert_receive {:agent_got, id, %{action: "update"} = command}, 2_000
    assert id == second.id

    Instances.command_finished(second.id, command.id, true, "ok")
    checked_now(second)

    state = wait_for(&(&1.status == :done))
    assert state.done == [first.id, second.id]
  end

  test "the first failed update stops the rest" do
    first = behind("A first")
    _second = behind("B second")

    assert :ok = Rollout.start("admin")
    assert_receive {:agent_got, _, command}

    Instances.command_finished(first.id, command.id, false, "pull failed")

    state = wait_for(&(&1.status == :failed))
    assert state.error =~ "pull failed"
    refute_receive {:agent_got, _, _}, 50
  end

  test "nothing starts when every site is up to date" do
    assert {:error, :nothing_to_update} = Rollout.start("admin")
  end
end
