defmodule BastionWeb.DomainLive.Show do
  use BastionWeb, :live_view
  alias Bastion.Domains

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Domains.get_domain(id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/domains")}

      domain ->
        if connected?(socket), do: Process.send_after(self(), :refresh, 15_000)

        {:ok,
         socket
         |> assign(
           page_title: domain.hostname,
           domain: domain,
           proof: nil,
           instance_options: instance_options(),
           form:
             to_form(%{"instance_id" => "", "purpose" => "site", "primary" => "false"},
               as: :binding
             )
         )}
    end
  end

  @impl true
  def handle_event("reserve", %{"binding" => attrs}, socket) do
    case Domains.reserve_with_proof(
           socket.assigns.domain.id,
           attrs["instance_id"],
           attrs["purpose"],
           attrs["primary"] == "true"
         ) do
      {:ok, {_binding, proof}} -> {:noreply, socket |> assign(proof: proof) |> reload()}
      _ -> {:noreply, put_flash(socket, :error, "Адрес уже занят или франшиза не найдена")}
    end
  end

  def handle_event("prepare", %{"binding-id" => id}, socket) do
    case Domains.request_prepare(id, nil, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Подготовка HTTPS запущена")}

      {:error, :waiting_dns} ->
        {:noreply, socket |> reload() |> put_flash(:info, "Ожидаем DNS")}

      {:error, reason} ->
        {:noreply, socket |> reload() |> put_flash(:error, "Адрес не готов: #{inspect(reason)}")}
    end
  end

  def handle_event("release", %{"binding-id" => id}, socket) do
    case Domains.request_release(id, socket.assigns.current_admin) do
      {:ok, _} ->
        {:noreply,
         socket |> assign(proof: nil) |> reload() |> put_flash(:info, "Освобождение запущено")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Не удалось освободить: #{inspect(reason)}")}
    end
  end

  def handle_event("save_zone_access", %{"zone" => attrs}, socket) do
    case Bastion.Domains.RegRu.save_credentials(
           socket.assigns.domain.zone,
           attrs["username"],
           attrs["password"]
         ) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "Доступ к зоне сохранён")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Не удалось сохранить доступ к зоне")}
    end
  end

  def handle_event("check_zone_access", _, socket) do
    case Bastion.Domains.RegRu.connection_check(socket.assigns.domain.zone) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Чтение, запись и уборка тестовой TXT записи прошли")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Проверка зоны не прошла: #{inspect(reason)}")}
    end
  end

  defp reload(socket), do: assign(socket, domain: Domains.get_domain(socket.assigns.domain.id))

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, 15_000)
    {:noreply, reload(socket)}
  end

  defp instance_options do
    Bastion.Nodes.active_placements()
    |> Map.values()
    |> Enum.filter(&Bastion.Nodes.ready?(&1.node))
    |> Enum.map(fn placement ->
      {"#{placement.instance.name} · #{placement.node.name}", placement.instance_id}
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <.link navigate={~p"/domains"} class="link">← Домены</.link>
      <h1 class="text-2xl font-bold">{@domain.hostname}</h1>
      <dl id="domain-details" class="grid gap-4 rounded-xl border p-5 sm:grid-cols-3">
        <div>
          <dt>Зона</dt><dd>{@domain.zone || "—"}</dd>
        </div>
        <div>
          <dt>Владелец</dt><dd>{@domain.owner || "—"}</dd>
        </div>
        <div>
          <dt>DNS</dt><dd>{@domain.dns_mode || "—"}</dd>
        </div>
        <div>
          <dt>Состояние</dt><dd>{state_label(@domain.state)}</dd>
        </div>
        <div>
          <dt>Последняя проверка</dt><dd>{inspect(@domain.observed_at)}</dd>
        </div>
        <div>
          <dt>Ошибка</dt><dd>{@domain.failure_reason || "—"}</dd>
        </div>
      </dl>
      <section :if={@domain.dns_mode == "regru" and @domain.zone} class="rounded-xl border p-5">
        <h2 class="font-semibold">Управление зоной REG.RU</h2>
        <.form
          for={to_form(%{}, as: :zone)}
          id="zone-credentials"
          phx-submit="save_zone_access"
          class="flex gap-3"
        >
          <.input name="zone[username]" value="" label="Логин REG.RU" required />
          <.input name="zone[password]" value="" type="password" label="Пароль API" required />
          <button class="btn btn-sm self-end">Сохранить</button>
        </.form>
        <button id="check-zone" class="btn btn-sm" phx-click="check_zone_access">Проверить подключение</button>
      </section>
      <.form
        for={@form}
        id="reserve-domain"
        phx-submit="reserve"
        class="flex gap-3 rounded-xl border p-5"
      >
        <.input
          field={@form[:instance_id]}
          type="select"
          options={@instance_options}
          label="Франшиза и сервер"
          required
        />
        <.input
          field={@form[:purpose]}
          type="select"
          options={[{"Витрина", "site"}, {"API", "api"}, {"Админка", "admin"}, {"Медиа", "media"}]}
          label="Назначение"
        />
        <.input
          field={@form[:primary]}
          type="select"
          options={[{"Дополнительный", "false"}, {"Основной", "true"}]}
          label="Привязка"
        />
        <button class="btn btn-primary self-end">Зарезервировать</button>
      </.form>
      <p :if={@proof} id="ownership-proof" class="rounded-xl border p-4">
        Опубликуйте TXT {@domain.hostname |> then(&("_delivest-verification." <> &1))}: <code>{@proof}</code>. Значение показано один раз.
      </p>
      <div
        :for={binding <- @domain.bindings}
        id={"binding-#{binding.id}"}
        class="rounded-xl border p-5"
      >
        <p>Франшиза {binding.instance_id} · {binding.purpose} · {state_label(binding.state)}</p>
        <p :if={binding.verification_name}>Подтверждение: TXT {binding.verification_name}</p>
        <div class="overflow-x-auto">
          <table class="table table-sm">
            <thead>
              <tr>
                <th>Тип</th><th>Имя</th><th>Ожидается</th><th>Обнаружено</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={type <- ~w(A AAAA)}>
                <td>{type}</td><td>{@domain.hostname}</td>
                <td>{addresses(binding.expected_records, type)}</td>
                <td>{addresses(binding.observed_records, type)}</td>
              </tr>
            </tbody>
          </table>
        </div>
        <p>
          Сертификат до: {format_time(binding.certificate_expires_at)} · Проверено: {format_time(
            binding.last_checked_at
          )}
        </p>
        <p :if={renewal_expiry(binding, @domain.hostname)} class="text-sm">
          Node сообщает срок действия: {renewal_expiry(binding, @domain.hostname)}
        </p>
        <p :if={binding.failure_reason}>Ошибка: {binding.failure_reason}. {binding.next_step}</p>
        <button
          :if={binding.state in ~w(reserved waiting_dns error)}
          class="btn btn-sm"
          phx-click="prepare"
          phx-value-binding-id={binding.id}
        >Проверить и подключить</button>
        <button
          :if={binding.state != "released"}
          class="btn btn-sm"
          phx-click="release"
          phx-value-binding-id={binding.id}
        >Освободить</button>
      </div>
    </Layouts.app>
    """
  end

  defp addresses(records, type) do
    records["addresses"]
    |> List.wrap()
    |> Enum.filter(fn value ->
      (String.contains?(value, ":") && type == "AAAA") ||
        (!String.contains?(value, ":") && type == "A")
    end)
    |> case do
      [] -> "—"
      values -> Enum.join(values, ", ")
    end
  end

  defp format_time(nil), do: "Нет данных"
  defp format_time(at), do: Calendar.strftime(at, "%d.%m.%Y %H:%M UTC")

  defp renewal_expiry(binding, hostname) do
    case Bastion.Nodes.placement_for(binding.instance_id) do
      %{node: node} -> get_in(node.infrastructure, ["renewal", "certificates", hostname])
      _ -> nil
    end
  end

  defp state_label("free"), do: "Свободен"
  defp state_label("reserved"), do: "Зарезервирован"
  defp state_label("waiting_dns"), do: "Ожидаем DNS"
  defp state_label("preparing_https"), do: "Готовим HTTPS"
  defp state_label("checking"), do: "Проверяем"
  defp state_label("connected"), do: "Подключён"
  defp state_label("released"), do: "Освобождён"
  defp state_label("error"), do: "Ошибка"
  defp state_label(value), do: value
end
