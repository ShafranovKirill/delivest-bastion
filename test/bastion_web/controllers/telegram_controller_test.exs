defmodule BastionWeb.TelegramControllerTest do
  use BastionWeb.ConnCase, async: false

  import Ecto.Query
  alias Bastion.{Repo, Telegram}
  alias Bastion.Telegram.UpdateWorker

  setup do
    keys = [:telegram_bot_token, :telegram_chat_id, :telegram_transport]
    previous = Enum.map(keys, &{&1, Application.fetch_env(:bastion, &1)})
    Application.put_env(:bastion, :telegram_bot_token, "test-bot")
    Application.put_env(:bastion, :telegram_chat_id, "42")
    Application.put_env(:bastion, :telegram_transport, :webhook)

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

  defp deliver(conn, update) do
    conn
    |> put_req_header("x-telegram-bot-api-secret-token", Telegram.webhook_secret())
    |> post("/telegram/webhook", update)
  end

  test "authenticates before queueing and requires integer update ids", %{conn: conn} do
    assert response(post(conn, "/telegram/webhook", %{"update_id" => 1}), 401) == ""

    wrong = put_req_header(conn, "x-telegram-bot-api-secret-token", "wrong")
    assert response(post(wrong, "/telegram/webhook", %{"update_id" => 1}), 401) == ""
    assert response(deliver(conn, %{"update_id" => "1"}), 400) == ""
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "receipt queues without making Telegram calls and deduplicates redelivery", %{conn: conn} do
    update = %{"update_id" => 5, "message" => %{"chat" => %{"id" => 42}, "text" => "/sites"}}
    assert json_response(deliver(conn, update), 200) == %{"ok" => true}
    job = Repo.one!(Oban.Job)
    assert job.worker == Oban.Worker.to_string(UpdateWorker)
    assert job.args["update"]["_telegram_acknowledged"] == false
    assert job.max_attempts == 1
    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id), set: [state: "completed"])
    assert json_response(deliver(conn, update), 200) == %{"ok" => true}
    assert Repo.aggregate(Oban.Job, :count) == 1
  end

  test "storage failures return a retryable response", %{conn: conn} do
    Repo.query!("ALTER TABLE oban_jobs RENAME TO unavailable_telegram_jobs")
    assert response(deliver(conn, %{"update_id" => 8}), 503) == ""
  end

  test "missing bot token rejects webhook requests", %{conn: conn} do
    conn = put_req_header(conn, "x-telegram-bot-api-secret-token", Telegram.webhook_secret())
    Application.put_env(:bastion, :telegram_bot_token, nil)
    assert response(post(conn, "/telegram/webhook", %{"update_id" => 9}), 401) == ""
    assert Repo.aggregate(Oban.Job, :count) == 0
  end

  test "authorized callbacks are acknowledged in the webhook HTTP response", %{conn: conn} do
    update = %{
      "update_id" => 6,
      "callback_query" => %{
        "id" => "q1",
        "data" => "sites",
        "message" => %{"chat" => %{"id" => 42}}
      }
    }

    assert json_response(deliver(conn, update), 200) == %{
             "method" => "answerCallbackQuery",
             "callback_query_id" => "q1"
           }

    assert Repo.one!(Oban.Job).args["update"]["_telegram_acknowledged"]
  end

  test "a caller cannot forge the acknowledgement marker", %{conn: conn} do
    update = %{
      "update_id" => 7,
      "_telegram_acknowledged" => true,
      "callback_query" => %{"id" => "q1", "message" => %{"chat" => %{"id" => 99}}}
    }

    assert json_response(deliver(conn, update), 200) == %{"ok" => true}
    refute Repo.one!(Oban.Job).args["update"]["_telegram_acknowledged"]
  end
end
