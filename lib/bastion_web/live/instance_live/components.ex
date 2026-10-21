defmodule BastionWeb.InstanceLive.Components do
  use BastionWeb, :html

  @levels %{
    ok: {"badge-success", "Работает"},
    warning: {"badge-warning", "Предупреждения"},
    down: {"badge-error", "Ошибки"},
    offline: {"badge-neutral", "Не на связи"},
    stopped: {"badge-info", "Выключен"},
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

  def revision(%{status: %{"containers" => containers}}, service) do
    Enum.find_value(containers, fn
      %{"service" => ^service, "revision" => revision} when is_binary(revision) ->
        String.slice(revision, 0, 7)

      _ ->
        nil
    end)
  end

  def revision(_instance, _service), do: nil

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

  def action_label("update"), do: "Обновление"
  def action_label("restart"), do: "Перезапуск"
  def action_label("stop"), do: "Выключение"
  def action_label("start"), do: "Включение"
  def action_label("logs"), do: "Логи"
  def action_label("status"), do: "Статус"
  def action_label("env_read"), do: "Чтение .env"
  def action_label("env_write"), do: "Запись .env"
  def action_label(action), do: action

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
