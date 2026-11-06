defmodule BastionWeb.InstanceLive.Components do
  use BastionWeb, :html

  alias BastionWeb.InstanceLive.Links

  @levels %{
    ok: {"badge-success", "Работает"},
    warning: {"badge-warning", "Предупреждения"},
    down: {"badge-error", "Ошибки"},
    offline: {"badge-neutral", "Нет свежих данных"},
    stopped: {"badge-info", "Выключен"},
    maintenance: {"badge-info", "Обслуживание"},
    unknown: {"badge-ghost", "Нет данных"}
  }

  attr :level, :atom, required: true

  def health_badge(assigns) do
    {class, label} = Map.fetch!(@levels, assigns.level)
    assigns = assign(assigns, class: class, label: label)

    ~H"""
    <span class={["badge whitespace-nowrap", @class]}>{@label}</span>
    """
  end

  attr :id, :string, required: true
  attr :host, :any, required: true
  attr :kind, :string, required: true
  attr :instance_name, :string, required: true

  def open_link(assigns) do
    url =
      if assigns.kind == "server",
        do: Links.server_url(assigns.host),
        else: Links.client_url(assigns.host)

    label = if assigns.kind == "server", do: "сервер", else: "клиент"
    assigns = assign(assigns, url: url, label: label)

    ~H"""
    <a
      :if={@url}
      id={@id}
      href={@url}
      target="_blank"
      rel="noopener noreferrer"
      aria-label={"Открыть #{@label} #{@instance_name} в новой вкладке"}
      class="inline-flex min-h-9 items-center gap-1 text-sm font-medium text-base-content/70 transition-colors hover:text-primary focus-visible:outline-2 focus-visible:outline-offset-2 focus-visible:outline-primary"
    >
      {if @kind == "server", do: "Админка", else: "Сайт"}
      <.icon name="hero-arrow-up-right" class="ml-1.5 size-4" />
    </a>
    <span :if={!@url} id={@id} class="text-sm text-base-content/50">Не настроен</span>
    """
  end

  attr :date, :any, required: true

  def payment_date(assigns) do
    assigns =
      assign(
        assigns,
        :days,
        assigns.date && Date.diff(assigns.date, Bastion.PaymentReminderWorker.today())
      )

    ~H"""
    <div :if={@date} class="space-y-0.5 tabular-nums">
      <div class="text-sm font-medium">До {Calendar.strftime(@date, "%d.%m.%Y")}</div>
      <div class={["text-xs", if(@days <= 0, do: "text-error", else: "text-base-content/50")]}>
        <%= cond do %>
          <% @days == 0 -> %>
            Оплата сегодня
          <% @days < 0 -> %>
            Просрочено: {abs(@days)} дн.
          <% true -> %>
            Осталось {@days} дн.
        <% end %>
      </div>
    </div>
    <span :if={!@date} class="text-sm text-base-content/40">Дата не указана</span>
    """
  end

  attr :instance, :any, required: true

  def site_version(assigns) do
    services =
      for service <- ["server", "client"],
          {current, available} = Bastion.Images.versions(assigns.instance, service),
          current != nil,
          do: %{name: service, current: current, available: available}

    assigns =
      assign(assigns, services: services, state: Bastion.Images.up_to_date?(assigns.instance))

    ~H"""
    <div class="space-y-1 text-xs tabular-nums">
      <div :for={service <- @services}>
        <span :if={length(@services) > 1} class="text-base-content/50">{if service.name == "server",
          do: "Сервер",
          else: "Клиент"} · </span>
        <span class="font-medium">{service.current}</span>
        <span :if={service.available} class="text-primary"> → {service.available}</span>
      </div>
      <span :if={@services == []} class="text-base-content/40">Версия неизвестна</span>
      <div class="text-base-content/50">
        <%= case @state do %>
          <% true -> %>
            Актуальна
          <% false -> %>
            <span class="text-primary">Есть обновление</span>
          <% :unknown -> %>
            Нет результата проверки
        <% end %>
      </div>
    </div>
    """
  end

  attr :online, :boolean, required: true

  def online_dot(assigns) do
    ~H"""
    <span
      class={["inline-block size-2.5 rounded-full", (@online && "bg-success") || "bg-base-300"]}
      title={(@online && "Агент на связи") || "Агент отключён"}
    ></span>
    """
  end

  attr :check, :map, default: nil

  def check(assigns) do
    ~H"""
    <span :if={is_nil(@check)} class="text-base-content/40">—</span>
    <span :if={@check && @check["ok"]} class="text-success whitespace-nowrap">
      {@check["status"]} · {@check["ms"]} мс
    </span>
    <span :if={@check && !@check["ok"]} class="text-error">
      {@check["status"] || @check["error"]}
    </span>
    """
  end

  def ago(nil), do: "никогда"

  def ago(%DateTime{} = at) do
    seconds = DateTime.diff(DateTime.utc_now(), at)

    cond do
      seconds < 60 -> "#{max(seconds, 0)} с назад"
      seconds < 3600 -> "#{div(seconds, 60)} мин назад"
      seconds < 86_400 -> "#{div(seconds, 3600)} ч назад"
      true -> "#{div(seconds, 86_400)} дн назад"
    end
  end

  def datetime(nil), do: "—"
  def datetime(%DateTime{} = at), do: Calendar.strftime(at, "%d.%m.%Y %H:%M:%S UTC")

  def disk_percent(%{status: %{"disk" => %{"used_kb" => used, "total_kb" => total}}})
      when total > 0,
      do: round(used / total * 100)

  def disk_percent(_instance), do: nil

  def format_uptime(uptime) when uptime >= 100, do: "100%"
  def format_uptime(uptime), do: :erlang.float_to_binary(uptime, decimals: 2) <> "%"

  def uptime_class(uptime) when uptime >= 99.9, do: "text-success"
  def uptime_class(uptime) when uptime >= 99, do: "text-warning"
  def uptime_class(_uptime), do: "text-error"

  def cert_days(nil), do: nil

  def cert_days(expires) do
    case DateTime.from_iso8601(expires) do
      {:ok, at, _} -> DateTime.diff(at, DateTime.utc_now(), :day)
      _ -> nil
    end
  end

  defdelegate action_label(action), to: Bastion.Instances

  attr :status, :string, required: true

  def command_status(assigns) do
    ~H"""
    <span class={[
      "badge badge-sm",
      @status == "ok" && "badge-success",
      @status == "error" && "badge-error",
      @status in ["sent", "running"] && "badge-info"
    ]}>
      {case @status do
        "sent" -> "отправлено"
        "running" -> "выполняется"
        "ok" -> "готово"
        "error" -> "ошибка"
        other -> other
      end}
    </span>
    """
  end
end
