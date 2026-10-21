defmodule Bastion.Health do
  alias Bastion.Instances.Instance

  @disk_warning 0.9
  @cert_warning_days 14

  def evaluate(%Instance{} = instance, now \\ DateTime.utc_now()) do
    cond do
      is_nil(instance.last_seen_at) ->
        %{level: :unknown, problems: []}

      not instance.online and stale?(instance, now) ->
        %{level: :offline, problems: ["агент не на связи с #{instance.last_seen_at}"]}

      true ->
        problems = problems(instance)
        warnings = warnings(instance, now)

        cond do
          problems != [] -> %{level: :down, problems: problems ++ warnings}
          warnings != [] -> %{level: :warning, problems: warnings}
          true -> %{level: :ok, problems: []}
        end
    end
  end

  def stale?(%Instance{last_seen_at: nil}, _now), do: true

  def stale?(%Instance{last_seen_at: seen}, now),
    do: DateTime.diff(now, seen) > Application.get_env(:bastion, :offline_after_seconds, 120)

  defp problems(instance) do
    status = instance.status || %{}

    error = if status["error"], do: ["агент: #{status["error"]}"], else: []

    containers =
      for %{"service" => service, "state" => state} <- List.wrap(status["containers"]),
          state != "running",
          do: "контейнер #{service}: #{state}"

    internal =
      for {kind, %{"ok" => false} = check} <- status["checks"] || %{},
          do: "#{label(kind)} не отвечает изнутри (#{reason(check)})"

    external =
      for {kind, %{"ok" => false} = check} <- instance.external || %{},
          do: "#{label(kind)} не отвечает снаружи (#{reason(check)})"

    error ++ containers ++ internal ++ external
  end

  defp warnings(instance, now) do
    disk =
      case (instance.status || %{})["disk"] do
        %{"used_kb" => used, "total_kb" => total}
        when total > 0 and used / total >= @disk_warning ->
          ["диск заполнен на #{round(used / total * 100)}%"]

        _ ->
          []
      end

    certs =
      for {kind, %{"cert_expires_at" => expires}} when is_binary(expires) <-
            instance.external || %{},
          {:ok, expires, _} <- [DateTime.from_iso8601(expires)],
          days = DateTime.diff(expires, now, :day),
          days < @cert_warning_days,
          do: "сертификат #{label(kind)} истекает через #{max(days, 0)} дн."

    stale =
      if instance.online and stale?(instance, now), do: ["нет свежих данных от агента"], else: []

    disk ++ certs ++ stale
  end

  defp label("api"), do: "API"
  defp label("site"), do: "сайт"
  defp label(kind), do: kind

  defp reason(%{"status" => status}), do: "HTTP #{status}"
  defp reason(%{"error" => error}), do: error
  defp reason(_check), do: "ошибка"
end
