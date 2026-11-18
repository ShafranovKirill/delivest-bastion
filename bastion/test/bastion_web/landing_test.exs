defmodule BastionWeb.LandingTest do
  use BastionWeb.ConnCase, async: false
  import Ecto.Query
  import Phoenix.LiveViewTest
  alias Bastion.{Landing, Repo}
  alias Bastion.Landing.{Event, Lead}

  defp event,
    do: %{
      "event_id" => "event-1",
      "session_id" => "session-1",
      "event" => "page_view",
      "path" => "/",
      "utm_source" => "yandex"
    }

  defp lead,
    do: %{
      "request_id" => "request-1",
      "session_id" => "session-1",
      "contact" => "+79991112233",
      "utm_source" => "yandex"
    }

  test "public config is allowlisted and admin page requires login", %{conn: conn} do
    assert %{"tracking_enabled" => true, "metrika_enabled" => false} =
             conn |> get("/api/landing/config") |> json_response(200)

    refute Map.has_key?(conn |> get("/api/landing/config") |> json_response(200), "yandex_token")
    assert {:error, {:redirect, %{to: "/login"}}} = live(conn, "/landing")
    {:ok, _, html} = live(init_test_session(conn, %{"admin" => "admin"}), "/landing")
    assert html =~ "Настройки лендинга"
  end

  test "events validate and deduplicate", %{conn: conn} do
    assert %{"ok" => true} = conn |> post("/api/landing/events", event()) |> json_response(202)
    assert %{"ok" => true} = conn |> post("/api/landing/events", event()) |> json_response(202)
    assert Repo.aggregate(Event, :count) == 1
    assert Landing.summary("7").sessions == 1

    assert conn
           |> post("/api/landing/events", Map.put(event(), "event", "made_up"))
           |> json_response(422)

    assert conn
           |> post(
             "/api/landing/events",
             Map.put(event(), "utm_source", String.duplicate("a", 501))
           )
           |> json_response(422)
  end

  test "leads save with analytics off, deduplicate and ignore honeypot", %{conn: conn} do
    assert {:ok, _} = Landing.update_settings(%{"tracking_enabled" => false})
    assert conn |> post("/api/landing/events", event()) |> json_response(422)
    first = conn |> post("/api/landing/leads", lead()) |> json_response(202)
    assert first["saved"] == true
    assert conn |> post("/api/landing/leads", lead()) |> json_response(202) == first
    assert Repo.aggregate(Lead, :count) == 1

    assert Repo.aggregate(
             from(j in Oban.Job, where: j.worker == "Bastion.Landing.LeadNotification"),
             :count
           ) == 1

    assert %{"saved" => false} =
             conn
             |> post("/api/landing/leads", Map.put(lead(), "website", "spam"))
             |> json_response(202)

    assert conn
           |> post("/api/landing/leads", Map.put(lead(), "contact", "x"))
           |> json_response(422)
  end

  test "settings reject invalid URL and preserve secret on blank update" do
    assert {:ok, _} =
             Landing.update_settings(%{
               "new_yandex_token" => "secret",
               "metrika_counter_id" => "123",
               "metrika_enabled" => true
             })

    assert {:ok, settings} =
             Landing.update_settings(%{
               "new_yandex_token" => "",
               "canonical_url" => "https://example.com"
             })

    assert settings.yandex_token == "secret"
    assert {:error, _} = Landing.update_settings(%{"canonical_url" => "http://unsafe.test"})
    assert {:error, _} = Landing.update_settings(%{"direct_campaign_ids" => [-1]})
  end

  test "notification failure does not remove an accepted lead", %{conn: conn} do
    previous = Application.get_env(:bastion, :telegram_bot_token)
    Application.put_env(:bastion, :telegram_bot_token, "test-bot")
    on_exit(fn -> Application.put_env(:bastion, :telegram_bot_token, previous) end)
    assert {:ok, _} = Landing.update_settings(%{"telegram_chat_ids" => ["42"]})
    response = conn |> post("/api/landing/leads", lead()) |> json_response(202)

    Req.Test.stub(Bastion.Http, fn conn ->
      Req.Test.json(conn, %{"ok" => false, "description" => "unavailable"})
    end)

    assert {:error, "unavailable"} =
             Bastion.Landing.LeadNotification.perform(%Oban.Job{
               args: %{"lead_id" => response["lead_id"]}
             })

    assert Repo.aggregate(Lead, :count) == 1
  end

  test "lead requests are limited per session", %{conn: conn} do
    for index <- 1..10 do
      attrs =
        lead() |> Map.put("session_id", "rate-session") |> Map.put("request_id", "rate-#{index}")

      assert conn |> post("/api/landing/leads", attrs) |> json_response(202)
    end

    attrs = lead() |> Map.put("session_id", "rate-session") |> Map.put("request_id", "rate-11")
    assert conn |> post("/api/landing/leads", attrs) |> json_response(429)
  end

  test "bot user agent cannot record events", %{conn: conn} do
    assert conn
           |> put_req_header("user-agent", "crawler bot")
           |> post("/api/landing/events", event())
           |> json_response(422)

    assert Repo.aggregate(Event, :count) == 0
  end

  test "admin saves settings, validates errors and never displays token", %{conn: conn} do
    {:ok, live, _} = live(init_test_session(conn, %{"admin" => "admin"}), "/landing")
    render_click(element(live, "button[phx-click='tab'][phx-value-tab='settings']"))

    html =
      live
      |> form("form[phx-submit='save']", %{
        "settings" => %{
          "canonical_url" => "https://example.com",
          "new_yandex_token" => "private-token",
          "metrika_counter_id" => "123"
        }
      })
      |> render_submit()

    assert Landing.settings().canonical_url == "https://example.com"
    assert Landing.settings().yandex_token == "private-token"
    refute html =~ "private-token"

    html =
      live
      |> form("form[phx-submit='save']", %{
        "settings" => %{"canonical_url" => "http://unsafe.test", "new_yandex_token" => ""}
      })
      |> render_submit()

    assert html =~ "must be an HTTPS URL"
    refute html =~ "private-token"
    assert Landing.settings().canonical_url == "https://example.com"
  end

  test "admin changes lead status", %{conn: conn} do
    assert {:ok, lead} = Landing.record_lead(lead())
    {:ok, live, _} = live(init_test_session(conn, %{"admin" => "admin"}), "/landing")
    render_click(element(live, "button[phx-click='tab'][phx-value-tab='leads']"))

    live
    |> form("form[phx-change='status']", %{"_lead_id" => lead.id, "status" => "contacted"})
    |> render_change()

    assert Repo.get!(Lead, lead.id).status == "contacted"
  end
end
