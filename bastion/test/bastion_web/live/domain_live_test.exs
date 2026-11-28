defmodule BastionWeb.DomainLiveTest do
  use BastionWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Bastion.{Domains, Nodes}

  test "owner adds an external address and sees its one-time TXT proof", %{conn: conn} do
    {:ok, node, token} = Nodes.create_node("Pilot server")
    {:ok, _, _credential} = Nodes.register(token, 1)

    assert :ok =
             Nodes.record_heartbeat(node.id, %{
               "sample_id" => "ready-1",
               "sampled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
               "version" => "0.1.0",
               "metrics" => %{},
               "instances" => [],
               "infrastructure" => %{"ready" => true, "checks" => %{}}
             })

    instance_id = Ecto.UUID.generate()
    {:ok, _} = Nodes.prepare_instance(node.id, instance_id, "Cafe", %{}, "cafe", 18080)
    conn = init_test_session(conn, %{"admin" => "admin"})

    {:ok, index, _} = live(conn, ~p"/domains")
    assert has_element?(index, "#new-domain")

    index
    |> form("#new-domain",
      domain: %{hostname: "Cafe.Example.ORG.", owner: "client", dns_mode: "external"}
    )
    |> render_submit()

    domain = Domains.list_domains() |> List.first()
    assert domain.hostname == "cafe.example.org"
    {:ok, show, _} = live(conn, ~p"/domains/#{domain.id}")
    assert has_element?(show, "#domain-details")

    show
    |> form("#reserve-domain",
      binding: %{instance_id: instance_id, purpose: "site", primary: "true"}
    )
    |> render_submit()

    assert has_element?(show, "#ownership-proof")
    assert has_element?(show, "#binding-#{List.first(Domains.get_domain(domain.id).bindings).id}")
    assert render(show) =~ "TXT _delivest-verification.cafe.example.org"
    assert render(show) =~ "Ожидается"

    {:ok, index, _} = live(conn, ~p"/domains")
    assert has_element?(index, "#domain-#{domain.id} a[href='/instances/#{instance_id}']", "Cafe")
  end
end
