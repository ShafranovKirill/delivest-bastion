defmodule Bastion.Landing do
  import Ecto.Query
  alias Bastion.Repo
  alias Bastion.Landing.{Settings, Event, Lead}

  @attribution ~w(utm_source utm_medium utm_campaign utm_content utm_term yclid referrer)
  @events ~w(page_view lead_open lead_success contact_telegram contact_vk contact_phone)

  def settings do
    Repo.get(Settings, 1) ||
      case Repo.insert(%Settings{id: 1}, on_conflict: :nothing) do
        {:ok, _} -> Repo.get!(Settings, 1)
        {:error, _} -> Repo.get!(Settings, 1)
      end
  end

  def update_settings(attrs) do
    attrs =
      Map.take(
        attrs,
        ~w(canonical_url tracking_enabled metrika_enabled metrika_counter_id direct_login direct_campaign_ids telegram_chat_ids new_yandex_token)
      )

    token = Map.get(attrs, "new_yandex_token")
    attrs = Map.delete(attrs, "new_yandex_token")

    attrs =
      if is_binary(token) and String.trim(token) != "",
        do: Map.put(attrs, "yandex_token", String.trim(token)),
        else: attrs

    changeset = settings() |> Settings.changeset(attrs)

    changeset =
      if Enum.any?(
           ~w(yandex_token metrika_counter_id direct_login direct_campaign_ids metrika_enabled)a,
           &Map.has_key?(changeset.changes, &1)
         ) do
        Enum.reduce(
          ~w(metrika_visits direct_spend_micros direct_clicks sync_from sync_to sync_at sync_error)a,
          changeset,
          &Ecto.Changeset.put_change(&2, &1, nil)
        )
      else
        changeset
      end

    Repo.update(changeset)
  end

  def public_config do
    s = settings()

    %{
      tracking_enabled: s.tracking_enabled,
      metrika_enabled: s.metrika_enabled,
      metrika_counter_id: s.metrika_counter_id
    }
  end

  def record_event(attrs) when is_map(attrs) do
    with true <- settings().tracking_enabled,
         {:ok, data} <-
           validate(
             attrs,
             %{"event_id" => 80, "session_id" => 80, "event" => 40},
             %{"path" => 300},
             @attribution
           ),
         true <- data["event"] in @events do
      changeset = Event.changeset(%Event{}, Map.put(data, "attribution", attribution(attrs)))
      Repo.insert(changeset, on_conflict: :nothing, conflict_target: :event_id)
    else
      false -> {:error, :invalid_or_disabled}
      error -> error
    end
  end

  def record_lead(attrs) when is_map(attrs) do
    with true <- blank?(Map.get(attrs, "website")) or {:ok, :honeypot},
         {:ok, data} <-
           validate(
             attrs,
             %{"request_id" => 80, "session_id" => 80, "contact" => 200},
             %{"name" => 120, "intent" => 500},
             @attribution
           ),
         true <- byte_size(data["contact"]) >= 5 do
      changeset = Lead.changeset(%Lead{}, Map.put(data, "attribution", attribution(attrs)))

      case Repo.insert(changeset,
             on_conflict: :nothing,
             conflict_target: :request_id,
             returning: true
           ) do
        {:ok, %Lead{id: nil}} ->
          {:ok, Repo.get_by!(Lead, request_id: data["request_id"])}

        {:ok, lead} ->
          _ = Bastion.Landing.LeadNotification.new(%{lead_id: lead.id}) |> Oban.insert()
          {:ok, lead}

        error ->
          error
      end
    else
      false -> {:error, :invalid_or_disabled}
      error -> error
    end
  end

  def list_leads(period \\ "7") do
    since = period_start(period)

    Repo.all(
      from l in Lead, where: l.inserted_at >= ^since, order_by: [desc: l.inserted_at], limit: 200
    )
  end

  def summary(period \\ "7") do
    since = period_start(period)

    views =
      Repo.aggregate(
        from(e in Event, where: e.inserted_at >= ^since and e.event == "page_view"),
        :count
      )

    sessions =
      Repo.one(
        from e in Event,
          where: e.inserted_at >= ^since and e.event == "page_view",
          select: count(e.session_id, :distinct)
      )

    leads = Repo.aggregate(from(l in Lead, where: l.inserted_at >= ^since), :count)

    converted_sessions =
      Repo.one(
        from e in Event,
          join: l in Lead,
          on: l.session_id == e.session_id,
          where: e.inserted_at >= ^since and l.inserted_at >= ^since and e.event == "page_view",
          select: count(e.session_id, :distinct)
      )

    sources =
      Repo.all(
        from e in Event,
          where: e.inserted_at >= ^since and e.event == "page_view",
          group_by: fragment("COALESCE(NULLIF(?->>'utm_source', ''), 'direct')", e.attribution),
          select:
            {fragment("COALESCE(NULLIF(?->>'utm_source', ''), 'direct')", e.attribution),
             count(e.id)},
          order_by: [desc: count(e.id)],
          limit: 5
      )

    %{
      views: views,
      sessions: sessions,
      leads: leads,
      converted_sessions: converted_sessions,
      sources: sources
    }
  end

  def attributed_lead_count(%Date{} = from, %Date{} = to, campaign_ids \\ []) do
    since = DateTime.new!(from, ~T[00:00:00], "Etc/UTC") |> DateTime.add(-3 * 3600)

    until_time =
      DateTime.new!(Date.add(to, 1), ~T[00:00:00], "Etc/UTC") |> DateTime.add(-3 * 3600)

    query =
      from l in Lead,
        where:
          l.inserted_at >= ^since and l.inserted_at < ^until_time and
            (fragment("NULLIF(?->>'yclid', '') IS NOT NULL", l.attribution) or
               (fragment("?->>'utm_source' = 'yandex'", l.attribution) and
                  fragment("?->>'utm_medium' IN ('cpc', 'ppc', 'direct')", l.attribution))),
        select: count(l.id)

    query =
      if campaign_ids == [],
        do: query,
        else:
          from(l in query,
            where:
              fragment("?->>'utm_campaign'", l.attribution) in ^Enum.map(
                campaign_ids,
                &to_string/1
              )
          )

    Repo.one(query)
  end

  def period_start("today"),
    do:
      DateTime.utc_now()
      |> DateTime.add(3 * 3600)
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-3 * 3600)

  def period_start("30"), do: period_start_days(29)
  def period_start(_), do: period_start_days(6)

  defp period_start_days(days),
    do:
      DateTime.utc_now()
      |> DateTime.add(3 * 3600)
      |> DateTime.to_date()
      |> Date.add(-days)
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-3 * 3600)

  def update_lead_status(id, status) when status in ~w(new contacted qualified closed) do
    case Repo.get(Lead, id) do
      nil -> {:error, :not_found}
      lead -> lead |> Lead.changeset(%{"status" => status}) |> Repo.update()
    end
  end

  def update_lead_status(_, _), do: {:error, :invalid_status}

  defp validate(attrs, required, optional, attribution) do
    allowed = Map.keys(required) ++ Map.keys(optional) ++ attribution ++ ["website"]

    if Enum.any?(Map.keys(attrs), &(&1 not in allowed)) or
         Enum.any?(required, fn {k, max} -> not valid?(attrs[k], max, true) end) or
         Enum.any?(optional, fn {k, max} -> not valid?(attrs[k], max, false) end) or
         Enum.any?(attribution, fn k -> not valid?(attrs[k], 500, false) end) or
         not valid?(attrs["website"], 200, false) do
      {:error, :invalid_payload}
    else
      {:ok, Map.take(attrs, Map.keys(required) ++ Map.keys(optional))}
    end
  end

  defp valid?(value, _, false) when is_nil(value), do: true

  defp valid?(value, max, required) when is_binary(value),
    do: byte_size(value) <= max and (not required or not blank?(value))

  defp valid?(_, _, _), do: false
  defp blank?(value), do: not is_binary(value) or String.trim(value) == ""
  defp attribution(attrs), do: Map.take(attrs, @attribution)
end
