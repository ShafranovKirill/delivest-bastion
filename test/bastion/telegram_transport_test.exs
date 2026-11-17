defmodule Bastion.TelegramTransportTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures
  use Oban.Testing, repo: Bastion.Repo

  alias Bastion.Telegram.{Server, UpdateWorker}
  alias Bastion.{Repo, Telegram}

  setup do
    keys = [:telegram_bot_token, :telegram_chat_id, :telegram_transport, :telegram_webhook_url]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:bastion, &1)})
    Application.put_env(:bastion, :telegram_bot_token, "test-bot")
    Application.put_env(:bastion, :telegram_chat_id, "42")
    Application.put_env(:bastion, :telegram_transport, :webhook)
    Application.put_env(:bastion, :telegram_webhook_url, "https://bastion.test/telegram/webhook")
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:telegram, List.last(conn.path_info), Jason.decode!(body)})
      Req.Test.json(conn, %{"ok" => true, "result" => true})
    end)

    on_exit(fn ->
      for {key, value} <- previous do
        case value do
          {:ok, value} -> Application.put_env(:bastion, key, value)
          :error -> Application.delete_env(:bastion, key)
        end
      end
    end)

    :ok
  end

  test "worker dispatches inbound messages and surfaces delivery errors" do
    update = %{"update_id" => 1, "message" => %{"chat" => %{"id" => 99}, "text" => "/sites"}}
    assert :ok = perform_job(UpdateWorker, %{kind: "update", id: 1, update: update})
    assert_received {:telegram, "sendMessage", %{"chat_id" => 99}}

    Req.Test.stub(Bastion.Http, fn conn ->
      Req.Test.json(conn, %{"ok" => false, "description" => "blocked"})
    end)

    assert {:error, "blocked"} =
             perform_job(UpdateWorker, %{kind: "update", id: 2, update: update})
  end

  test "obsolete command notifications are skipped and each status is unique" do
    instance = instance_fixture()

    command =
      Repo.insert!(%Bastion.Instances.Command{
        instance_id: instance.id,
        action: "restart",
        status: "ok"
      })

    assert :ok = perform_job(UpdateWorker, %{kind: "command", id: command.id, status: "running"})
    refute_received {:telegram, _, _}
    assert {:ok, first} = UpdateWorker.enqueue_command(command)
    assert {:ok, duplicate} = UpdateWorker.enqueue_command(command)
    assert duplicate.id == first.id
    assert {:ok, progress} = UpdateWorker.enqueue_command(%{command | status: "running"})
    refute progress.id == first.id
  end

  test "polling stops at an unqueued update and redelivery does not duplicate earlier jobs" do
    ref = make_ref()

    state = %{
      offset: 7,
      poll: %Task{ref: ref, owner: self(), pid: self(), mfa: {Server, :start_link, 1}}
    }

    first = %{"update_id" => 7}
    last = %{"update_id" => 9}

    assert {:noreply, %{offset: 8, poll: nil} = retry_state} =
             Server.handle_info({ref, {:ok, [first, %{"update_id" => "8"}, last]}}, state)

    assert Repo.aggregate(Oban.Job, :count) == 1
    ref = make_ref()

    retry_state = %{
      retry_state
      | poll: %Task{ref: ref, owner: self(), pid: self(), mfa: {Server, :start_link, 1}}
    }

    assert {:noreply, %{offset: 10, poll: nil}} =
             Server.handle_info({ref, {:ok, [first, %{"update_id" => 8}, last]}}, retry_state)

    assert Repo.aggregate(Oban.Job, :count) == 3
  end

  test "setup errors schedule retry and never start polling" do
    Req.Test.stub(Bastion.Http, fn conn ->
      Req.Test.json(conn, %{"ok" => false, "description" => "temporarily unavailable"})
    end)

    state = %{offset: nil, poll: nil}
    assert {:noreply, ^state} = Server.handle_info(:setup, state)
    refute_received {:telegram, "getUpdates", _}
  end

  test "webhook setup never starts a long poll and command events only enqueue" do
    state = %{offset: nil, poll: nil}
    assert {:noreply, ^state} = Server.handle_info(:setup, state)
    assert_received {:telegram, "setWebhook", _}
    refute_received {:telegram, "getUpdates", _}

    command = %{id: Ecto.UUID.generate(), status: "running"}
    assert {:noreply, ^state} = Server.handle_info({:command_updated, command}, state)
    assert Repo.one!(Oban.Job).args["id"] == command.id
    refute_received {:telegram, "sendMessage", _}
    refute Telegram.polling?()
  end
end
