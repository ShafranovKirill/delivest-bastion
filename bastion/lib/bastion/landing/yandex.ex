defmodule Bastion.Landing.Yandex do
  import Ecto.Query
  alias Bastion.{Landing, Repo}
  alias Bastion.Landing.Settings

  @metrika "https://api-metrika.yandex.net/stat/v1/data"
  @direct "https://api.direct.yandex.com/json/v501/reports"

  def refresh do
    settings = Landing.settings()

    case fetch(settings) do
      {:ok, data} ->
        update_if_current(
          settings,
          Map.merge(data, %{
            sync_at: DateTime.utc_now() |> DateTime.truncate(:second),
            sync_error: nil
          })
        )

      {:error, reason} ->
        _ = update_if_current(settings, %{sync_error: safe_reason(reason)})
        {:error, reason}
    end
  end

  defp update_if_current(original, attrs) do
    Repo.transaction(fn ->
      current = Repo.one!(from s in Settings, where: s.id == 1, lock: "FOR UPDATE")

      if config_key(current) == config_key(original) do
        current |> Settings.changeset(attrs) |> Repo.update!()
      else
        Repo.rollback(:config_changed)
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, updated}
      error -> error
    end
  end

  defp config_key(s),
    do:
      {s.yandex_token, s.metrika_counter_id, s.direct_login, s.direct_campaign_ids,
       s.metrika_enabled}

  def fetch(%Settings{yandex_token: token} = s) when is_binary(token) and token != "" do
    to = DateTime.utc_now() |> DateTime.add(3 * 3600) |> DateTime.to_date()
    from = Date.add(to, -6)

    with {:ok, visits} <- metrika(s, token, from, to),
         {:ok, direct} <- direct(s, token, from, to) do
      {:ok, Map.merge(direct, %{metrika_visits: visits, sync_from: from, sync_to: to})}
    end
  end

  def fetch(_), do: {:error, :missing_token}

  defp metrika(%Settings{metrika_counter_id: nil}, _, _, _), do: {:error, :missing_counter}

  defp metrika(s, token, from, to) do
    opts =
      [
        params: [
          ids: s.metrika_counter_id,
          metrics: "ym:s:visits",
          date1: Date.to_iso8601(from),
          date2: Date.to_iso8601(to)
        ],
        headers: [{"Authorization", "OAuth #{token}"}],
        receive_timeout: 10_000,
        retry: :transient,
        max_retries: 1
      ] ++ req_options()

    case Req.get(@metrika, opts) do
      {:ok, %{status: 200, body: %{"totals" => [visits | _]}}} when is_number(visits) ->
        {:ok, trunc(visits)}

      {:ok, %{status: status}} ->
        {:error, {:metrika_http, status}}

      {:error, _} ->
        {:error, :metrika_transport}

      _ ->
        {:error, :invalid_metrika_response}
    end
  end

  defp direct(%Settings{direct_login: nil}, _, _, _), do: {:error, :missing_direct_login}

  defp direct(s, token, from, to) do
    criteria = %{"DateFrom" => Date.to_iso8601(from), "DateTo" => Date.to_iso8601(to)}

    criteria =
      if s.direct_campaign_ids == [],
        do: criteria,
        else:
          Map.put(criteria, "Filter", [
            %{
              "Field" => "CampaignId",
              "Operator" => "IN",
              "Values" => Enum.map(s.direct_campaign_ids, &to_string/1)
            }
          ])

    params = %{
      "SelectionCriteria" => criteria,
      "FieldNames" => ["CampaignId", "Clicks", "Cost"],
      "ReportType" => "CAMPAIGN_PERFORMANCE_REPORT",
      "DateRangeType" => "CUSTOM_DATE",
      "Format" => "TSV",
      "IncludeVAT" => "NO",
      "IncludeDiscount" => "NO"
    }

    digest =
      Jason.encode!(%{"login" => s.direct_login, "params" => params})
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)
      |> binary_part(0, 16)

    body =
      Jason.encode!(%{"params" => Map.put(params, "ReportName", "DelivestLanding-#{digest}")})

    opts =
      [
        body: body,
        headers: [
          {"Authorization", "Bearer #{token}"},
          {"Client-Login", s.direct_login},
          {"Accept-Language", "ru"},
          {"processingMode", "auto"},
          {"returnMoneyInMicros", "true"},
          {"Content-Type", "application/json"}
        ],
        receive_timeout: 15_000,
        retry: false
      ] ++ req_options()

    direct_request(opts, 0)
  end

  defp direct_request(opts, attempt) do
    case Req.post(@direct, opts) do
      {:ok, %{status: 200, body: report}} when is_binary(report) ->
        parse_report(report)

      {:ok, %{status: status} = response} when status in [201, 202] and attempt < 2 ->
        wait_ms =
          case Req.Response.get_header(response, "retryin") do
            [value | _] ->
              case Integer.parse(value) do
                {seconds, ""} when seconds >= 0 -> seconds * 1_000
                _ -> 1_000
              end

            _ ->
              1_000
          end

        if wait_ms <= 2_000 do
          Process.sleep(wait_ms)
          direct_request(opts, attempt + 1)
        else
          {:error, :direct_pending}
        end

      {:ok, %{status: status}} when status in [201, 202] ->
        {:error, :direct_pending}

      {:ok, %{status: status}} ->
        {:error, {:direct_http, status}}

      {:error, _} ->
        {:error, :direct_transport}

      _ ->
        {:error, :invalid_direct_response}
    end
  end

  defp parse_report(report) do
    rows = String.split(report, ~r/\r?\n/, trim: true)

    case Enum.find_index(rows, &(&1 == "CampaignId\tClicks\tCost")) do
      nil ->
        {:error, :invalid_direct_report}

      index ->
        rows
        |> Enum.drop(index + 1)
        |> Enum.reject(&(String.starts_with?(&1, "Total") or String.starts_with?(&1, "Итого")))
        |> Enum.reduce_while({:ok, %{direct_spend_micros: 0, direct_clicks: 0}}, fn row,
                                                                                    {:ok, sums} ->
          case String.split(row, "\t") do
            [_id, clicks, cost] ->
              case {Integer.parse(clicks), Integer.parse(cost)} do
                {{clicks, ""}, {cost, ""}} when clicks >= 0 and cost >= 0 ->
                  {:cont,
                   {:ok,
                    %{
                      direct_spend_micros: sums.direct_spend_micros + cost,
                      direct_clicks: sums.direct_clicks + clicks
                    }}}

                _ ->
                  {:halt, {:error, :invalid_direct_report}}
              end

            _ ->
              {:halt, {:error, :invalid_direct_report}}
          end
        end)
    end
  end

  defp safe_reason({:metrika_http, status}), do: "Метрика: HTTP #{status}"
  defp safe_reason({:direct_http, status}), do: "Директ: HTTP #{status}"
  defp safe_reason(:missing_token), do: "Не задан OAuth токен"
  defp safe_reason(:missing_counter), do: "Не задан счётчик Метрики"
  defp safe_reason(:missing_direct_login), do: "Не задан логин Директа"
  defp safe_reason(:direct_pending), do: "Отчёт Директа ещё готовится. Обновите позже"
  defp safe_reason(_), do: "Ошибка ответа Яндекса"
  defp req_options, do: Application.get_env(:bastion, :req_options, [])
end
