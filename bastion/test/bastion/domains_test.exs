defmodule Bastion.DomainsTest do
  use Bastion.DataCase, async: false

  import Bastion.Fixtures

  alias Bastion.Domains

  setup do
    Application.put_env(:bastion, :domain_dns_resolver, Bastion.TestDomainDNS)
    Application.put_env(:bastion, :test_domain_addresses, {:ok, ["8.8.8.8"]})
    Application.put_env(:bastion, :test_domain_txt, {:ok, []})

    on_exit(fn ->
      Application.delete_env(:bastion, :domain_dns_resolver)
      Application.delete_env(:bastion, :test_domain_addresses)
      Application.delete_env(:bastion, :test_domain_txt)
    end)

    :ok
  end

  test "canonical domain is reserved for only one franchise" do
    first = instance_fixture()
    second = instance_fixture()

    assert {:ok, domain} = Domains.create_domain(%{"hostname" => "Cafe.Example.COM."})
    assert domain.hostname == "cafe.example.com"
    assert {:error, changeset} = Domains.create_domain(%{"hostname" => "cafe.example.com"})
    assert errors_on(changeset).hostname

    assert {:ok, binding} = Domains.reserve(domain.id, first.id, "site", true)
    assert binding.instance_id == first.id
    assert {:error, :already_bound} = Domains.reserve(domain.id, second.id, "site", true)
  end

  test "invalid labels are rejected and Unicode names match their A-label" do
    assert {:error, _} = Domains.create_domain(%{"hostname" => "-invalid.example"})
    assert {:ok, domain} = Domains.create_domain(%{"hostname" => "Пример.РФ."})
    assert domain.hostname == "xn--e1afmkfd.xn--p1ai"
    assert {:error, _} = Domains.create_domain(%{"hostname" => domain.hostname})
  end

  test "external TXT proof gates a domain command and is invalidated after release" do
    {:ok, node, _token} = Bastion.Nodes.create_node("Pilot")
    {:ok, node} = Bastion.Nodes.update_public_addresses(node, %{"public_ipv4" => "8.8.8.8"})
    id = Ecto.UUID.generate()
    {:ok, _placement} = Bastion.Nodes.prepare_instance(node.id, id, "Pilot", %{}, "pilot", 18080)

    {:ok, domain} =
      Domains.create_domain(%{"hostname" => "cafe.example.org", "dns_mode" => "external"})

    {:ok, {binding, proof}} = Domains.reserve_with_proof(domain.id, id, "site")

    assert {:error, :waiting_dns} = Domains.request_prepare(binding.id, nil, "admin")
    assert Domains.get_domain(domain.id).state == "waiting_dns"

    assert Repo.get(Bastion.Domains.Binding, binding.id).expected_records == %{
             "addresses" => ["8.8.8.8"]
           }

    Application.put_env(:bastion, :test_domain_txt, {:ok, [proof]})
    Bastion.Domains.DnsPoller.poll()
    assert [operation] = Bastion.Nodes.operations_for(id)
    assert operation.action == "domain_prepare"
    assert operation.args["hostname"] == "cafe.example.org"
    assert operation.args["expected_addresses"] == ["8.8.8.8"]
    assert operation.instance_id == id
    assert {:error, :busy} = Bastion.Nodes.queue(id, "domain_prepare", "admin", operation.args)

    assert {:ok, %{status: "ok"}} =
             Bastion.Nodes.update_operation(node.id, operation.id, "command_result", %{
               "status" => "ok",
               "result" => %{
                 "verified" => true,
                 "binding_id" => binding.id,
                 "hostname" => domain.hostname,
                 "certificate_expires_at" => "2027-01-01T00:00:00Z"
               }
             })

    Req.Test.stub(Bastion.Http, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-delivest-binding-id", binding.id)
      |> Plug.Conn.send_resp(200, "ready")
    end)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
    assert Domains.get_domain(domain.id).state == "connected"
    assert {:error, :connected_address_requires_node_release} = Domains.release(binding.id)

    assert {:ok, release} = Domains.request_release(binding.id, "admin")
    assert release.action == "domain_release"

    assert {:ok, %{status: "ok"}} =
             Bastion.Nodes.update_operation(node.id, release.id, "command_result", %{
               "status" => "ok",
               "result" => %{
                 "released" => true,
                 "binding_id" => binding.id,
                 "hostname" => domain.hostname
               }
             })

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
    assert Domains.get_domain(domain.id).state == "free"
    assert Repo.get(Bastion.Domains.Binding, binding.id).verification_token_hash == nil
    assert {:ok, {_new_binding, new_proof}} = Domains.reserve_with_proof(domain.id, id, "site")
    refute proof == new_proof
  end

  test "wrong DNS waits without sending a Node command" do
    {:ok, node, _} = Bastion.Nodes.create_node("Pilot")
    {:ok, node} = Bastion.Nodes.update_public_addresses(node, %{"public_ipv4" => "8.8.8.8"})
    id = Ecto.UUID.generate()
    {:ok, _} = Bastion.Nodes.prepare_instance(node.id, id, "Pilot", %{}, "pilot", 18080)

    {:ok, domain} =
      Domains.create_domain(%{"hostname" => "cafe.example.org", "dns_mode" => "external"})

    {:ok, {binding, proof}} = Domains.reserve_with_proof(domain.id, id, "site")
    Application.put_env(:bastion, :test_domain_txt, {:ok, [proof]})
    Application.put_env(:bastion, :test_domain_addresses, {:ok, ["1.1.1.1"]})
    assert {:error, :waiting_dns} = Domains.request_prepare(binding.id, nil, "admin")
    assert Domains.get_domain(domain.id).state == "waiting_dns"
    assert Bastion.Nodes.operations_for(id) == []
  end

  test "HTTPS probe checks the actual binding and purpose without accepting server errors" do
    id = Ecto.UUID.generate()

    Req.Test.stub(Bastion.Http, fn conn ->
      status = if conn.request_path == "/ready", do: 200, else: 403

      conn
      |> Plug.Conn.put_resp_header("x-delivest-binding-id", id)
      |> Plug.Conn.send_resp(status, "route")
    end)

    assert {:ok, _} = Bastion.Domains.HttpsProbe.check("cafe.example.org", id, ["8.8.8.8"], "api")

    assert {:ok, _} =
             Bastion.Domains.HttpsProbe.check("cafe.example.org", id, ["8.8.8.8"], "media")

    assert {:error, {:http_status, 403}} =
             Bastion.Domains.HttpsProbe.check("cafe.example.org", id, ["8.8.8.8"], "site")

    Req.Test.stub(Bastion.Http, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-delivest-binding-id", Ecto.UUID.generate())
      |> Plug.Conn.send_resp(200, "wrong")
    end)

    assert {:error, :wrong_route} =
             Bastion.Domains.HttpsProbe.check("cafe.example.org", id, ["8.8.8.8"], "site")

    Req.Test.stub(Bastion.Http, fn conn -> Plug.Conn.send_resp(conn, 500, "down") end)

    assert {:error, {:http_status, 500}} =
             Bastion.Domains.HttpsProbe.check("cafe.example.org", id, ["8.8.8.8"], "site")
  end

  test "release waits for in-flight DNS preparation and cannot free its route" do
    {:ok, node, _} = Bastion.Nodes.create_node("Pilot")
    {:ok, node} = Bastion.Nodes.update_public_addresses(node, %{"public_ipv4" => "8.8.8.8"})
    id = Ecto.UUID.generate()
    {:ok, _} = Bastion.Nodes.prepare_instance(node.id, id, "Pilot", %{}, "pilot", 18080)

    {:ok, domain} =
      Domains.create_domain(%{"hostname" => "race.example.org", "dns_mode" => "external"})

    {:ok, {binding, proof}} = Domains.reserve_with_proof(domain.id, id, "site")
    Application.put_env(:bastion, :domain_dns_resolver, Bastion.BlockingDomainDNS)
    Application.put_env(:bastion, :dns_block_pid, self())
    Application.put_env(:bastion, :test_domain_txt, {:ok, [proof]})
    on_exit(fn -> Application.delete_env(:bastion, :dns_block_pid) end)
    parent = self()

    start_supervised!(
      {Task,
       fn -> send(parent, {:prepared, Domains.request_prepare(binding.id, nil, "admin")}) end},
      id: :prepare_task
    )

    assert_receive {:dns_waiting, dns_task}

    start_supervised!(
      {Task,
       fn ->
         send(parent, :release_started)
         send(parent, {:released, Domains.release(binding.id)})
       end},
      id: :release_task
    )

    assert_receive :release_started
    refute_receive {:released, _}, 100
    send(dns_task, :continue)
    assert_receive {:prepared, {:ok, _operation}}
    assert_receive {:released, {:error, :connected_address_requires_node_release}}, 2_000
    assert Repo.get(Bastion.Domains.Binding, binding.id).state == "preparing_https"
    assert length(Bastion.Nodes.operations_for(id)) == 1
  end
end
