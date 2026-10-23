defmodule Bastion.PushTest do
  use BastionWeb.ConnCase, async: false
  use Oban.Testing, repo: Bastion.Repo

  alias Bastion.{Alerts, Push, Repo}
  alias Bastion.Push.Subscription

  defp browser_keys do
    {public, _private} = :crypto.generate_key(:ecdh, :prime256v1)

    %{
      "p256dh" => Base.url_encode64(public, padding: false),
      "auth" => Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false)
    }
  end

  defp log_in(conn), do: init_test_session(conn, %{"admin" => "admin"})

  test "a logged in admin turns the alerts on and off for a device", %{conn: conn} do
    body = %{"endpoint" => "https://push.example.com/abc", "keys" => browser_keys()}

    assert redirected_to(post(conn, ~p"/push/subscriptions", body)) == ~p"/login"

    assert %{"ok" => true} =
             build_conn() |> log_in() |> post(~p"/push/subscriptions", body) |> json_response(200)

    assert %Subscription{admin: "admin"} = Repo.get_by(Subscription, endpoint: body["endpoint"])

    build_conn()
    |> log_in()
    |> delete(~p"/push/subscriptions", %{"endpoint" => body["endpoint"]})
    |> json_response(200)

    refute Push.any?()
  end

  test "alerts are pushed to the instance page and dead subscriptions are dropped" do
    {:ok, _} =
      Push.subscribe(
        %{
          endpoint: "https://push.example.com/live",
          p256dh: browser_keys()["p256dh"],
          auth: browser_keys()["auth"]
        },
        "admin"
      )

    {:ok, _} =
      Push.subscribe(
        %{
          endpoint: "https://push.example.com/gone",
          p256dh: browser_keys()["p256dh"],
          auth: browser_keys()["auth"]
        },
        "admin"
      )

    id = Ecto.UUID.generate()

    Alerts.send_message("🔴 Pizza: сайт лежит\nAPI не отвечает", %{
      reply_markup: Bastion.Telegram.keyboard([[{"Открыть", "i:" <> id}]])
    })

    assert_enqueued(worker: Push.Worker, args: %{url: "/instances/" <> id})

    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      # Req.Test strips content-encoding before the plug, so the record header is checked.
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      <<_salt::binary-16, record_size::32, 65, _key::binary-65, _rest::binary>> = body
      send(test_pid, {:push, conn.request_path, record_size})

      status = if conn.request_path == "/gone", do: 410, else: 201
      Plug.Conn.send_resp(conn, status, "")
    end)

    assert :ok =
             perform_job(Push.Worker, %{text: "🔴 Pizza: сайт лежит", url: "/instances/" <> id})

    assert_received {:push, "/live", 4096}
    assert_received {:push, "/gone", _}

    assert [%{endpoint: "https://push.example.com/live"}] = Repo.all(Subscription)
  end

  test "nothing is queued without subscriptions" do
    assert :skipped = Push.notify("тест")
  end
end
