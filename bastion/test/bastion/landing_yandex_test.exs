defmodule Bastion.LandingYandexTest do
  use Bastion.DataCase, async: false
  alias Bastion.Landing
  alias Bastion.Landing.Lead
  alias Bastion.Repo
  alias Bastion.Landing.Yandex

  test "filters configured campaigns and imports only successful reports" do
    assert {:ok, _} =
             Landing.update_settings(%{
               "new_yandex_token" => "private",
               "metrika_counter_id" => "123",
               "direct_login" => "account",
               "direct_campaign_ids" => [42]
             })

    Req.Test.stub(Bastion.Http, fn conn ->
      case conn.request_path do
        "/stat/v1/data" ->
          params = URI.decode_query(conn.query_string)
          send(self(), {:metrika_dates, params["date1"], params["date2"]})
          Req.Test.json(conn, %{"totals" => [12]})

        "/json/v501/reports" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          data = Jason.decode!(body)

          send(
            self(),
            {:direct_dates, get_in(data, ["params", "SelectionCriteria", "DateFrom"]),
             get_in(data, ["params", "SelectionCriteria", "DateTo"])}
          )

          assert get_in(data, ["params", "SelectionCriteria", "Filter"]) == [
                   %{"Field" => "CampaignId", "Operator" => "IN", "Values" => ["42"]}
                 ]

          Plug.Conn.send_resp(conn, 200, "CampaignId\tClicks\tCost\n42\t3\t5000000\n")
      end
    end)

    assert {:ok, settings} = Yandex.refresh()
    assert settings.metrika_visits == 12
    assert settings.direct_spend_micros == 5_000_000
    assert settings.direct_clicks == 3
    assert settings.sync_from && settings.sync_to
    assert_receive {:metrika_dates, from, to}
    assert_receive {:direct_dates, ^from, ^to}
    assert from == Date.to_iso8601(settings.sync_from)

    Req.Test.stub(Bastion.Http, fn conn -> Plug.Conn.send_resp(conn, 403, "denied") end)
    assert {:error, {:metrika_http, 403}} = Yandex.refresh()
    latest = Landing.settings()
    assert latest.metrika_visits == 12
    assert latest.direct_spend_micros == 5_000_000
    assert latest.sync_error == "Метрика: HTTP 403"
    refute latest.sync_error =~ "private"
  end

  test "invalid, negative and pending Direct reports preserve old snapshot" do
    assert {:ok, _} =
             Landing.update_settings(%{
               "new_yandex_token" => "private",
               "metrika_counter_id" => "123",
               "direct_login" => "account"
             })

    for {status, report} <- [
          {200, "bad"},
          {200, "CampaignId\tClicks\tCost\n42\t3\t-5\n"},
          {201, ""},
          {202, ""}
        ] do
      Req.Test.stub(Bastion.Http, fn conn ->
        if conn.request_path == "/stat/v1/data",
          do: Req.Test.json(conn, %{"totals" => [12]}),
          else: Plug.Conn.send_resp(conn, status, report)
      end)

      assert {:error, _} = Yandex.refresh()
      assert is_nil(Landing.settings().direct_spend_micros)
      assert is_nil(Landing.settings().metrika_visits)
    end
  end

  test "attributed leads exclude organic, empty yclid and other campaign or date" do
    today = DateTime.utc_now() |> DateTime.add(3 * 3600) |> DateTime.to_date()
    start = DateTime.new!(today, ~T[00:00:00], "Etc/UTC") |> DateTime.add(-3 * 3600)

    insert = fn id, attribution, time ->
      Repo.insert!(%Lead{
        request_id: id,
        session_id: id,
        contact: "+79991112233",
        attribution: attribution,
        inserted_at: time,
        updated_at: time
      })
    end

    insert.(
      "organic",
      %{"utm_source" => "yandex", "utm_medium" => "organic", "yclid" => ""},
      start
    )

    insert.(
      "paid42",
      %{"utm_source" => "yandex", "utm_medium" => "cpc", "utm_campaign" => "42"},
      start
    )

    insert.("paid43", %{"yclid" => "abc", "utm_campaign" => "43"}, start)
    insert.("before", %{"yclid" => "abc", "utm_campaign" => "42"}, DateTime.add(start, -1))
    assert Landing.attributed_lead_count(today, today) == 2
    assert Landing.attributed_lead_count(today, today, [42]) == 1
  end

  test "Direct pending report retries and a changed token invalidates the snapshot" do
    assert {:ok, _} =
             Landing.update_settings(%{
               "new_yandex_token" => "private",
               "metrika_counter_id" => "123",
               "direct_login" => "account"
             })

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Bastion.Http, fn conn ->
      if conn.request_path == "/stat/v1/data" do
        Req.Test.json(conn, %{"totals" => [9]})
      else
        attempt = Agent.get_and_update(counter, fn n -> {n, n + 1} end)

        if attempt == 0 do
          conn |> Plug.Conn.put_resp_header("retryin", "0") |> Plug.Conn.send_resp(201, "pending")
        else
          Plug.Conn.send_resp(conn, 200, "CampaignId\tClicks\tCost\n42\t2\t1000000\n")
        end
      end
    end)

    assert {:ok, settings} = Yandex.refresh()
    assert Agent.get(counter, & &1) == 2
    assert settings.direct_spend_micros == 1_000_000

    assert {:ok, settings} = Landing.update_settings(%{"new_yandex_token" => "another"})
    assert is_nil(settings.direct_spend_micros)
    assert is_nil(settings.metrika_visits)
    assert is_nil(settings.sync_at)
  end

  test "refresh does not store statistics fetched for an outdated configuration" do
    assert {:ok, _} =
             Landing.update_settings(%{
               "new_yandex_token" => "private",
               "metrika_counter_id" => "123",
               "direct_login" => "account"
             })

    Req.Test.stub(Bastion.Http, fn conn ->
      if conn.request_path == "/stat/v1/data" do
        Req.Test.json(conn, %{"totals" => [9]})
      else
        assert {:ok, _} = Landing.update_settings(%{"direct_campaign_ids" => [42]})
        Plug.Conn.send_resp(conn, 200, "CampaignId\tClicks\tCost\n42\t2\t1000000\n")
      end
    end)

    assert {:error, :config_changed} = Yandex.refresh()
    assert is_nil(Landing.settings().direct_spend_micros)
  end

  test "long Direct retryIn returns pending without early polling or zero snapshot" do
    assert {:ok, _} =
             Landing.update_settings(%{
               "new_yandex_token" => "private",
               "metrika_counter_id" => "123",
               "direct_login" => "account"
             })

    {:ok, counter} = Agent.start_link(fn -> 0 end)

    Req.Test.stub(Bastion.Http, fn conn ->
      if conn.request_path == "/stat/v1/data" do
        Req.Test.json(conn, %{"totals" => [9]})
      else
        Agent.update(counter, &(&1 + 1))
        conn |> Plug.Conn.put_resp_header("retryin", "60") |> Plug.Conn.send_resp(201, "pending")
      end
    end)

    assert {:error, :direct_pending} = Yandex.refresh()
    assert Agent.get(counter, & &1) == 1
    assert is_nil(Landing.settings().direct_spend_micros)
    assert Landing.settings().sync_error =~ "готовится"
  end

  test "Direct report name is stable for identical parameters and changes with scope" do
    assert {:ok, settings} =
             Landing.update_settings(%{
               "new_yandex_token" => "private",
               "metrika_counter_id" => "123",
               "direct_login" => "account",
               "direct_campaign_ids" => [42]
             })

    Req.Test.stub(Bastion.Http, fn conn ->
      if conn.request_path == "/stat/v1/data" do
        Req.Test.json(conn, %{"totals" => [9]})
      else
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        params = Jason.decode!(body)["params"]
        send(self(), {:report, params["ReportName"], params})
        Plug.Conn.send_resp(conn, 200, "CampaignId\tClicks\tCost\n42\t2\t1000000\n")
      end
    end)

    assert {:ok, _} = Yandex.fetch(settings)
    assert_receive {:report, name, params}
    assert {:ok, _} = Yandex.fetch(settings)
    assert_receive {:report, ^name, ^params}

    expected =
      Jason.encode!(%{
        "login" => settings.direct_login,
        "params" => Map.delete(params, "ReportName")
      })
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    assert name == "DelivestLanding-#{expected}"
    assert {:ok, _} = Yandex.fetch(%{settings | direct_campaign_ids: [43]})
    assert_receive {:report, other_name, _}
    refute other_name == name
    assert {:ok, _} = Yandex.fetch(%{settings | direct_login: "another"})
    assert_receive {:report, login_name, _}
    refute login_name == name
  end
end
