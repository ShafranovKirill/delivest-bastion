defmodule BastionWeb.LandingLive do
  use BastionWeb, :live_view
  alias Bastion.Landing
  alias Bastion.Landing.Yandex

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(30_000, :refresh_landing)

    {:ok,
     socket
     |> assign(page_title: "Настройки лендинга", tab: "overview", period: "7", refreshing: false)
     |> load()}
  end

  @impl true
  def handle_event("tab", %{"tab" => tab}, socket) when tab in ~w(overview settings leads),
    do: {:noreply, socket |> assign(tab: tab) |> load()}

  def handle_event("period", %{"period" => period}, socket) when period in ~w(today 7 30),
    do: {:noreply, socket |> assign(period: period) |> load()}

  def handle_event("save", %{"settings" => params}, socket) do
    params = normalize_settings(params)

    case Landing.update_settings(params) do
      {:ok, _} -> {:noreply, socket |> put_flash(:info, "Настройки сохранены") |> load()}
      {:error, changeset} -> {:noreply, assign(socket, form: to_form(changeset, as: :settings))}
    end
  end

  def handle_event("status", %{"_lead_id" => id, "status" => status}, socket) do
    case Landing.update_lead_status(id, status) do
      {:ok, _} -> {:noreply, load(socket)}
      _ -> {:noreply, put_flash(socket, :error, "Не удалось изменить статус")}
    end
  end

  def handle_event("refresh", _, socket) do
    if socket.assigns.refreshing,
      do: {:noreply, socket},
      else:
        {:noreply,
         socket
         |> assign(refreshing: true)
         |> start_async(:yandex_refresh, fn -> Yandex.refresh() end)}
  end

  @impl true
  def handle_info(:refresh_landing, socket),
    do: {:noreply, if(socket.assigns.tab in ~w(overview leads), do: load(socket), else: socket)}

  @impl true
  def handle_async(:yandex_refresh, {:ok, {:ok, _}}, socket),
    do:
      {:noreply,
       socket
       |> assign(refreshing: false)
       |> put_flash(:info, "Данные Яндекса обновлены")
       |> load()}

  def handle_async(:yandex_refresh, {:ok, {:error, :direct_pending}}, socket),
    do:
      {:noreply,
       socket
       |> assign(refreshing: false)
       |> put_flash(:info, "Отчёт Директа готовится. Повторите обновление позже")
       |> load()}

  def handle_async(:yandex_refresh, _, socket),
    do:
      {:noreply,
       socket
       |> assign(refreshing: false)
       |> put_flash(:error, "Не удалось обновить данные Яндекса")
       |> load()}

  defp load(socket) do
    settings = Landing.settings()

    assign(socket,
      settings: settings,
      form: to_form(Bastion.Landing.Settings.changeset(settings, %{}), as: :settings),
      summary: Landing.summary(socket.assigns.period),
      leads: Landing.list_leads(socket.assigns.period),
      attributed_leads:
        if(settings.sync_from && settings.sync_to,
          do:
            Landing.attributed_lead_count(
              settings.sync_from,
              settings.sync_to,
              settings.direct_campaign_ids
            ),
          else: nil
        )
    )
  end

  defp normalize_settings(params) do
    params
    |> Map.update("direct_campaign_ids", [], &ids/1)
    |> Map.update("telegram_chat_ids", [], &strings/1)
  end

  defp ids(value),
    do:
      value
      |> strings()
      |> Enum.map(fn s ->
        case Integer.parse(s) do
          {i, ""} -> i
          _ -> 0
        end
      end)

  defp strings(value) when is_binary(value),
    do: value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

  defp strings(value) when is_list(value), do: value
  defp strings(_), do: []

  defp status_label("new"), do: "Новая"
  defp status_label("contacted"), do: "Связались"
  defp status_label("qualified"), do: "Подходит"
  defp status_label("closed"), do: "Закрыта"

  defp intent_label("pricing"), do: "Расчёт подключения"
  defp intent_label("demo"), do: "Демонстрация"
  defp intent_label(_), do: "Обращение"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <h1 class="text-2xl font-bold">Настройки лендинга</h1>
      <div class="tabs tabs-boxed">
        <button
          :for={
            {tab, label} <- [{"overview", "Обзор"}, {"settings", "Настройки"}, {"leads", "Заявки"}]
          }
          type="button"
          class={["tab", @tab == tab && "tab-active"]}
          phx-click="tab"
          phx-value-tab={tab}
        >{label}</button>
      </div>
      <section :if={@tab == "overview"} class="space-y-4">
        <div class="flex gap-2">
          <button
            :for={{period, label} <- [{"today", "Сегодня"}, {"7", "7 дней"}, {"30", "30 дней"}]}
            type="button"
            class={["btn btn-sm", @period == period && "btn-primary"]}
            phx-click="period"
            phx-value-period={period}
          >{label}</button>
        </div>
        <div class="grid grid-cols-1 gap-4 sm:grid-cols-3">
          <div class="stat bg-base-200 rounded">
            <div class="stat-title">Просмотры</div><div class="stat-value">{@summary.views}</div>
          </div>
          <div class="stat bg-base-200 rounded">
            <div class="stat-title">Визиты</div><div class="stat-value">{@summary.sessions}</div><div class="stat-desc whitespace-normal">
              Новый визит после 30 минут бездействия
            </div>
          </div>
          <div class="stat bg-base-200 rounded">
            <div class="stat-title">Заявки</div><div class="stat-value">{@summary.leads}</div>
          </div>
        </div>
        <p>
          Доля визитов с заявкой: {if @summary.sessions > 0,
            do:
              :erlang.float_to_binary(100.0 * @summary.converted_sessions / @summary.sessions,
                decimals: 1
              ) <> "%",
            else: "Нет данных"}
        </p>
        <div>
          <h2 class="font-semibold">Источники просмотров</h2><p :for={
            {source, count} <- @summary.sources
          }>
            {source}: {count}
          </p>
        </div>
        <div class="card bg-base-200 p-4 space-y-2">
          <h2 class="text-lg font-semibold">Яндекс Метрика и Директ</h2>
          <p :if={@settings.sync_from && @settings.sync_to}>
            Данные за {@settings.sync_from} — {@settings.sync_to}, московское время. Расход в валюте кабинета без НДС.
          </p>
          <p :if={@settings.sync_at}>
            Последнее успешное обновление: {Calendar.strftime(@settings.sync_at, "%d.%m.%Y %H:%M UTC")}
          </p>
          <p :if={@settings.sync_error} class="text-error">
            Ошибка обновления: {@settings.sync_error}
          </p>
          <p>
            Визиты за 7 дней: {if is_nil(@settings.metrika_visits),
              do: "Нет данных",
              else: @settings.metrika_visits}
          </p>
          <p>
            Расход за 7 дней: {if is_nil(@settings.direct_spend_micros),
              do: "Нет данных",
              else: :erlang.float_to_binary(@settings.direct_spend_micros / 1_000_000, decimals: 2)}
          </p>
          <p>
            Цена заявки из Директа: {if is_nil(@settings.direct_spend_micros) or
                                          is_nil(@attributed_leads) or @attributed_leads == 0,
                                        do: "Нет данных",
                                        else:
                                          :erlang.float_to_binary(
                                            @settings.direct_spend_micros / 1_000_000 /
                                              @attributed_leads,
                                            decimals: 2
                                          )}
          </p>
          <p :if={@settings.direct_campaign_ids != []}>
            Для цены заявки по выбранным кампаниям передавайте utm_source=yandex, utm_medium=cpc и utm_campaign=ID кампании.
          </p>
          <p :if={@settings.direct_clicks}>Клики Директа: {@settings.direct_clicks}</p>
          <button
            type="button"
            class="btn btn-sm btn-primary w-fit"
            phx-click="refresh"
            disabled={@refreshing}
          >{if @refreshing, do: "Обновление…", else: "Обновить из Яндекса"}</button>
        </div>
      </section>
      <section :if={@tab == "settings"} class="space-y-4 max-w-xl">
        <p>
          Для чтения статистики нужен OAuth токен с доступом к Метрике и Директу. Получить его можно в <a
            class="link"
            href="https://oauth.yandex.ru/"
            target="_blank"
            rel="noopener"
          >Яндекс OAuth</a>. Токен хранится на сервере; пустое поле сохраняет текущий токен.
        </p>
        <p>Токен: {if @settings.yandex_token, do: "подключён", else: "не задан"}</p>
        <.form for={@form} phx-submit="save" class="space-y-3">
          <.input field={@form[:canonical_url]} label="Адрес лендинга" />
          <.input
            field={@form[:tracking_enabled]}
            type="checkbox"
            label="Собственная аналитика"
          />
          <.input field={@form[:metrika_enabled]} type="checkbox" label="Яндекс Метрика" />
          <.input field={@form[:metrika_counter_id]} label="ID счётчика Метрики" />
          <p>
            Цели Метрики: lead_open, lead_success, contact_telegram, contact_vk, contact_phone. Создайте цели JavaScript-события с этими идентификаторами в счётчике.
          </p>
          <.input field={@form[:direct_login]} label="Логин Директа" />
          <.input
            name="settings[direct_campaign_ids]"
            value={Enum.join(@settings.direct_campaign_ids, ", ")}
            label="ID кампаний через запятую"
          />
          <.input
            name="settings[telegram_chat_ids]"
            value={Enum.join(@settings.telegram_chat_ids, ", ")}
            label="Telegram chat ID через запятую"
          />
          <.input
            name="settings[new_yandex_token]"
            type="password"
            value=""
            label="Новый OAuth токен"
            autocomplete="new-password"
          />
          <button class="btn btn-primary">Сохранить</button>
        </.form>
      </section>
      <section :if={@tab == "leads"} class="overflow-x-auto">
        <table class="table">
          <thead>
            <tr>
              <th>Дата</th><th>Имя</th><th>Контакт</th><th>Запрос</th><th>Источник</th><th>Статус</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={lead <- @leads}>
              <td>
                {Calendar.strftime(DateTime.add(lead.inserted_at, 3 * 3600), "%d.%m.%Y %H:%M")} МСК
              </td><td>{lead.name || "—"}</td><td>
                {lead.contact}
              </td><td>{intent_label(lead.intent)}</td><td>
                {lead.attribution["utm_source"] || "Прямой"}<span
                  :if={lead.attribution["utm_campaign"]}
                  class="block text-xs"
                >Кампания: {lead.attribution["utm_campaign"]}</span>
              </td><td>
                <form id={"lead-status-#{lead.id}"} phx-change="status">
                  <input type="hidden" name="_lead_id" value={lead.id} /><select
                    name="status"
                    class="select select-bordered select-sm"
                  ><option
                    :for={status <- ~w(new contacted qualified closed)}
                    value={status}
                    selected={lead.status == status}
                  >
                    {status_label(status)}
                  </option></select>
                </form>
              </td>
            </tr>
          </tbody>
        </table>
      </section>
    </Layouts.app>
    """
  end
end
