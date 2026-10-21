defmodule Bastion.ChecksTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.Checks.{External, Worker}
  alias Bastion.Instances

  setup do
    on_exit(fn ->
      Application.delete_env(:bastion, :telegram_chat_id)
      Application.put_env(:bastion, :telegram_bot_token, nil)
    end)
  end

  defp stub(fun), do: Req.Test.stub(Bastion.Http, fun)

  test "external checks request every public host" do
    stub(fn conn ->
      case conn.host do
        "api.example.com" -> Plug.Conn.send_resp(conn, 200, "ok")
        "site.example.com" -> Plug.Conn.send_resp(conn, 503, "down")
      end
    end)

    assert %{
             "api" => %{"ok" => true, "status" => 200},
             "site" => %{"ok" => false, "status" => 503}
           } =
             External.run(%{
               "api" => "api.example.com",
               "site" => "site.example.com",
               "s3" => "s3.example.com"
             })
  end

  test "the worker stores the health and alerts on changes" do
    Application.put_env(:bastion, :telegram_bot_token, "bot")
    Application.put_env(:bastion, :telegram_chat_id, "42")
    test_pid = self()

    stub(fn
      %{host: "api.telegram.org"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:telegram, Jason.decode!(body)["text"]})
        Req.Test.json(conn, %{"ok" => true})

      %{host: "api.example.com"} = conn ->
        Plug.Conn.send_resp(conn, 502, "")

      conn ->
        Plug.Conn.send_resp(conn, 200, "ok")
    end)

    instance = instance_fixture(%{info: %{"name" => "Pizza"}})
    {:ok, _} = Instances.record_heartbeat(instance.id, healthy_status())

    assert :ok = perform_job()

    assert [%{health: "down", external: %{"api" => %{"status" => 502}}}] =
             Instances.list_instances()

    assert_received {:telegram,
                     "🔴 Pizza: сайт работает с ошибками\n• API не отвечает снаружи (HTTP 502)"}

    assert :ok = perform_job()
    refute_received {:telegram, _}
  end

  defp perform_job, do: Worker.perform(%Oban.Job{})
end
