defmodule BastionWeb.DomainLive.Index do
  use BastionWeb, :live_view
  alias Bastion.Domains

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Домены",
       form:
         to_form(%{"hostname" => "", "zone" => "", "owner" => "client", "dns_mode" => "external"},
           as: :domain
         )
     )
     |> load()}
  end

  @impl true
  def handle_event("create", %{"domain" => attrs}, socket) do
    case Domains.create_domain(attrs) do
      {:ok, domain} ->
        {:noreply, push_navigate(socket, to: ~p"/domains/#{domain.id}")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(form: to_form(changeset))
         |> put_flash(:error, "Проверьте имя и уникальность адреса")}
    end
  end

  defp load(socket) do
    domains = Domains.list_domains()

    socket
    |> assign(:domain_count, length(domains))
    |> stream(:domains, domains, reset: true, dom_id: &"domain-#{&1.id}")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_admin={@current_admin}>
      <h1 class="text-2xl font-bold">Домены</h1>
      <.form
        for={@form}
        id="new-domain"
        phx-submit="create"
        class="grid gap-3 rounded-xl border p-5 md:grid-cols-4"
      >
        <.input field={@form[:hostname]} label="Полное доменное имя" required />
        <.input field={@form[:zone]} label="Родительская зона" />
        <.input field={@form[:owner]} label="Владелец" />
        <.input
          field={@form[:dns_mode]}
          type="select"
          options={[{"Внешний DNS", "external"}, {"REG.RU", "regru"}, {"Ручное управление", "manual"}]}
          label="Управление DNS"
        />
        <button class="btn btn-primary md:col-span-4">Добавить адрес</button>
      </.form>
      <div id="domains" class="overflow-x-auto rounded-xl border border-base-300">
        <table class="table">
          <thead>
            <tr>
              <th>Адрес</th><th>Зона</th><th>DNS</th><th>Состояние</th><th>Франшиза</th>
            </tr>
          </thead>
          <tbody id="domain-rows" phx-update="stream">
            <tr :for={{dom_id, domain} <- @streams.domains} id={dom_id}>
              <td>
                <.link navigate={~p"/domains/#{domain.id}"} class="link">{domain.hostname}</.link>
              </td>
              <td>{domain.zone || "—"}</td><td>{domain.dns_mode || "—"}</td><td>
                {state_label(domain.state)}
              </td>
              <td :if={active_binding(domain)}>
                <.link navigate={~p"/instances/#{active_binding(domain).instance_id}"} class="link">
                  {active_binding(domain).instance.name}
                </.link>
              </td>
              <td :if={!active_binding(domain)}>Свободен</td>
            </tr>
          </tbody>
        </table>
        <p :if={@domain_count == 0} class="p-4">Адресов пока нет.</p>
      </div>
    </Layouts.app>
    """
  end

  defp state_label("free"), do: "Свободен"
  defp state_label("reserved"), do: "Зарезервирован"
  defp state_label("waiting_dns"), do: "Ожидаем DNS"
  defp state_label("preparing_https"), do: "Готовим HTTPS"
  defp state_label("checking"), do: "Проверяем"
  defp state_label("connected"), do: "Подключён"
  defp state_label("error"), do: "Ошибка"
  defp state_label(value), do: value

  defp active_binding(domain), do: Enum.find(domain.bindings, &(&1.state != "released"))
end
