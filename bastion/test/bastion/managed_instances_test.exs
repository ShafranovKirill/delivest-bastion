defmodule Bastion.ManagedInstancesTest do
  use Bastion.DataCase, async: false

  alias Bastion.{Domains, ManagedInstances, Nodes, Repo}
  alias Bastion.Nodes.Operation
  alias Bastion.Releases.Managed

  setup do
    Application.put_env(:bastion, :domain_dns_resolver, Bastion.TestDomainDNS)
    Application.put_env(:bastion, :domain_reg_ru_adapter, Bastion.FakeManagedDNS)
    Application.put_env(:bastion, :test_domain_addresses, {:ok, ["8.8.8.8"]})
    Application.put_env(:bastion, :test_domain_txt, {:ok, []})

    on_exit(fn ->
      Enum.each(
        ~w(domain_dns_resolver domain_reg_ru_adapter test_domain_addresses test_domain_txt)a,
        &Application.delete_env(:bastion, &1)
      )
    end)

    Req.Test.stub(Bastion.Http, fn conn ->
      Req.Test.json(conn, %{
        "tag_name" => "v1.25.0",
        "draft" => false,
        "prerelease" => false,
        "published_at" => "2026-11-28T00:00:00Z",
        "assets" => [
          %{
            "name" => "delivest-deploy-1.25.0.tar.gz",
            "digest" => "sha256:" <> String.duplicate("a", 64),
            "browser_download_url" =>
              "https://github.com/ShafranovKirill/delivest/releases/download/v1.25.0/delivest-deploy-1.25.0.tar.gz"
          }
        ]
      })
    end)

    :ok
  end

  test "only the published immutable deployment asset is accepted" do
    assert {:ok, %{version: "1.25.0", sha256: sha}} = Managed.latest()
    assert sha == String.duplicate("a", 64)

    Req.Test.stub(Bastion.Http, fn conn ->
      Req.Test.json(conn, %{
        "tag_name" => "v1.25.0",
        "draft" => false,
        "prerelease" => false,
        "published_at" => "2026-11-28T00:00:00Z",
        "assets" => [
          %{
            "name" => "delivest-deploy-1.25.0.tar.gz",
            "digest" => "sha256:" <> String.duplicate("a", 64),
            "browser_download_url" => "https://evil.invalid/archive.tar.gz"
          }
        ]
      })
    end)

    assert {:error, :release_package_unavailable} = Managed.latest()
  end

  test "creation reserves one ID, pinned release, port and three hostnames; retry preserves them" do
    node = ready_node("pilot")
    id = Ecto.UUID.generate()
    attrs = %{"instance_id" => id, "node_id" => node.id, "name" => "Cafe", "short_name" => "cafe"}

    assert {:ok, %Operation{status: "waiting_external"} = operation, nil} =
             ManagedInstances.create(attrs, "owner")

    assert operation.args["release_version"] == "1.25.0"
    assert operation.args["site_hostname"] == "cafe.delivest.ru"
    assert operation.args["admin_hostname"] == operation.args["api_hostname"]
    assert operation.args["admin_binding_id"] == operation.args["api_binding_id"]
    assert Nodes.placement_for(id).gateway_port == operation.args["gateway_port"]
    assert length(ManagedInstances.bindings(id)) == 3

    Req.Test.stub(Bastion.Http, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
    assert {:ok, %Operation{id: same_id}} = ManagedInstances.retry_create(id)
    assert same_id == operation.id

    assert {:error, :release_unavailable} =
             ManagedInstances.create(%{attrs | "instance_id" => Ecto.UUID.generate()}, "owner")

    assert length(Nodes.operations_for(id)) == 1
  end

  test "existing domain and port cannot be reserved by a second franchise" do
    node = ready_node("pilot")
    first = Ecto.UUID.generate()
    second = Ecto.UUID.generate()

    attrs = %{
      "node_id" => node.id,
      "name" => "Cafe",
      "short_name" => "cafe",
      "instance_id" => first
    }

    assert {:ok, _, _} = ManagedInstances.create(attrs, "owner")
    assert {:error, _} = ManagedInstances.create(%{attrs | "instance_id" => second}, "owner")
    assert Nodes.placement_for(second) == nil
    assert length(Domains.list_domains()) == 3
  end

  test "DNS gate dispatches the pinned operation and only public HTTPS checks mark it ready" do
    node = ready_node("pilot")
    id = Ecto.UUID.generate()
    attrs = %{"node_id" => node.id, "name" => "Cafe", "short_name" => "cafe", "instance_id" => id}
    {:ok, operation, _} = ManagedInstances.create(attrs, "owner")

    assert :ok = ManagedInstances.advance(operation.id)
    operation = Repo.get!(Operation, operation.id)
    assert operation.status == "pending"
    assert operation.progress["stage"] == "dns_ready"

    args = operation.args

    Req.Test.stub(Bastion.Http, fn conn ->
      binding_id =
        case conn.host do
          "cafe.delivest.ru" -> args["site_binding_id"]
          "api-cafe.delivest.ru" -> args["api_binding_id"]
          "media-cafe.delivest.ru" -> args["media_binding_id"]
        end

      conn
      |> Plug.Conn.put_resp_header("x-delivest-binding-id", binding_id)
      |> Plug.Conn.send_resp(200, "ready")
    end)

    assert {:ok, %{status: "ok"}} =
             Nodes.update_operation(node.id, operation.id, "command_result", %{
               "status" => "ok",
               "result" => %{
                 "stage" => "ready",
                 "instance_id" => id,
                 "project_name" => Nodes.placement_for(id).project_name,
                 "gateway_port" => args["gateway_port"],
                 "release_version" => "1.25.0"
               }
             })

    assert %{success: success, failure: 0} = Oban.drain_queue(queue: :default)
    assert success >= 1
    assert Enum.all?(ManagedInstances.bindings(id), &(&1.state == "connected"))
    assert Repo.get!(Operation, operation.id).status == "ok"
  end

  test "prepared site requires recorded browser confirmation before one action activation" do
    {node, id, args} = created_instance()
    new_binding = prepared_site(id)

    assert {:error, :not_verified} = ManagedInstances.activate(new_binding.id, "owner")
    assert {:ok, _} = ManagedInstances.confirm_browser(new_binding.id, "owner")
    assert {:ok, activation} = ManagedInstances.activate(new_binding.id, "owner")

    assert activation.args["verification_id"] ==
             Repo.get!(Domains.Binding, new_binding.id).observed_records["browser_verification"][
               "id"
             ]

    Req.Test.stub(Bastion.Http, fn conn ->
      if conn.host == "cafe.delivest.ru" do
        conn
        |> Plug.Conn.put_resp_header(
          "location",
          "https://new.example.org" <> conn.request_path <> "?check=1"
        )
        |> Plug.Conn.send_resp(308, "")
      else
        binding_id =
          case conn.host do
            "new.example.org" -> new_binding.id
            "api-cafe.delivest.ru" -> args["api_binding_id"]
            "media-cafe.delivest.ru" -> args["media_binding_id"]
          end

        conn
        |> Plug.Conn.put_resp_header("x-delivest-binding-id", binding_id)
        |> Plug.Conn.send_resp(200, "ok")
      end
    end)

    assert {:ok, _} =
             Nodes.update_operation(node.id, activation.id, "command_result", %{
               "status" => "ok",
               "result" => %{
                 "activated" => true,
                 "hostname" => "new.example.org",
                 "binding_id" => new_binding.id,
                 "previous_hostname" => "cafe.delivest.ru",
                 "previous_binding_id" => args["site_binding_id"]
               }
             })

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
    assert Repo.get!(Domains.Binding, new_binding.id).primary
    refute Repo.get!(Domains.Binding, args["site_binding_id"]).primary
    assert Repo.get!(Bastion.Instances.Instance, id).hosts["site"] == "new.example.org"
  end

  test "failed external redirect check keeps old primary and queues rollback with same verification" do
    {node, id, args} = created_instance()
    new_binding = prepared_site(id)
    {:ok, _} = ManagedInstances.confirm_browser(new_binding.id, "owner")
    {:ok, activation} = ManagedInstances.activate(new_binding.id, "owner")

    Req.Test.stub(Bastion.Http, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-delivest-binding-id", new_binding.id)
      |> Plug.Conn.send_resp(200, "no redirect")
    end)

    {:ok, _} =
      Nodes.update_operation(node.id, activation.id, "command_result", %{
        "status" => "ok",
        "result" => %{
          "activated" => true,
          "hostname" => "new.example.org",
          "binding_id" => new_binding.id,
          "previous_hostname" => "cafe.delivest.ru",
          "previous_binding_id" => args["site_binding_id"]
        }
      })

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
    assert Repo.get!(Domains.Binding, args["site_binding_id"]).primary
    refute Repo.get!(Domains.Binding, new_binding.id).primary
    assert Repo.get!(Bastion.Instances.Instance, id).hosts["site"] == "cafe.delivest.ru"
    assert [rollback, _activation | _] = Nodes.operations_for(id)
    assert rollback.action == "domain_rollback"
    assert rollback.args == activation.args
    assert rollback.status == "pending"
  end

  defp created_instance do
    node = ready_node("pilot")
    id = Ecto.UUID.generate()

    {:ok, operation, _} =
      ManagedInstances.create(
        %{
          "node_id" => node.id,
          "name" => "Cafe",
          "short_name" => "cafe",
          "instance_id" => id
        },
        "owner"
      )

    :ok = ManagedInstances.advance(operation.id)
    args = operation.args

    Req.Test.stub(Bastion.Http, fn conn ->
      binding_id =
        case conn.host do
          "cafe.delivest.ru" -> args["site_binding_id"]
          "api-cafe.delivest.ru" -> args["api_binding_id"]
          "media-cafe.delivest.ru" -> args["media_binding_id"]
        end

      conn
      |> Plug.Conn.put_resp_header("x-delivest-binding-id", binding_id)
      |> Plug.Conn.send_resp(200, "ok")
    end)

    {:ok, _} =
      Nodes.update_operation(node.id, operation.id, "command_result", %{
        "status" => "ok",
        "result" => %{
          "stage" => "ready",
          "instance_id" => id,
          "project_name" => Nodes.placement_for(id).project_name,
          "gateway_port" => args["gateway_port"],
          "release_version" => "1.25.0"
        }
      })

    %{success: _, failure: 0} = Oban.drain_queue(queue: :default)
    {node, id, args}
  end

  defp prepared_site(id) do
    {:ok, domain} =
      Domains.create_domain(%{"hostname" => "new.example.org", "dns_mode" => "external"})

    {:ok, {binding, proof}} = Domains.reserve_with_proof(domain.id, id, "site", false)
    Application.put_env(:bastion, :test_domain_txt, {:ok, [proof]})
    {:ok, prepare} = Domains.request_prepare(binding.id, nil, "owner")

    Req.Test.stub(Bastion.Http, fn conn ->
      conn
      |> Plug.Conn.put_resp_header("x-delivest-binding-id", binding.id)
      |> Plug.Conn.send_resp(200, "ok")
    end)

    {:ok, _} =
      Nodes.update_operation(prepare.node_id, prepare.id, "command_result", %{
        "status" => "ok",
        "result" => %{
          "verified" => true,
          "binding_id" => binding.id,
          "hostname" => domain.hostname,
          "certificate_expires_at" => "2027-01-01T00:00:00Z"
        }
      })

    %{success: 1, failure: 0} = Oban.drain_queue(queue: :default)
    Repo.get!(Domains.Binding, binding.id)
  end

  defp ready_node(name) do
    {:ok, node, token} = Nodes.create_node(name)
    {:ok, _, _} = Nodes.register(token, 1)
    {:ok, _} = Nodes.update_public_addresses(node, %{"public_ipv4" => "8.8.8.8"})

    :ok =
      Nodes.record_heartbeat(node.id, %{
        "sample_id" => Ecto.UUID.generate(),
        "sampled_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
        "version" => "0.1.0",
        "metrics" => %{},
        "instances" => [],
        "infrastructure" => %{"ready" => true}
      })

    Repo.get!(Nodes.Node, node.id)
  end
end
