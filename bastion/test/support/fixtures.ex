defmodule Bastion.Fixtures do
  alias Bastion.Instances

  def release_fixture(version \\ "1.2.3") do
    manifest = %{
      "version" => version,
      "root_sha" => String.duplicate("a", 40),
      "gitlinks" => Map.new(~w(server client agent), &{&1, String.duplicate("b", 40)}),
      "images" => Map.new(~w(server client agent), &{&1, "sha256:" <> String.duplicate("c", 64)})
    }

    Bastion.Repo.insert!(%Bastion.Releases.Bundle{version: version, manifest: manifest},
      on_conflict: :nothing
    )

    manifest
  end

  def instance_fixture(attrs \\ %{}) do
    id = Map.get(attrs, :id, Ecto.UUID.generate())

    info =
      Map.merge(
        %{
          "name" => "Pizza #{System.unique_integer([:positive])}",
          "hosts" => %{"api" => "api.example.com", "site" => "site.example.com"},
          "agent_version" => "0.1.0",
          "actions" => Instances.actions()
        },
        Map.get(attrs, :info, %{})
      )

    {:ok, instance} = Instances.register(id, info)
    instance
  end

  def healthy_status do
    %{
      "containers" => [
        %{"service" => "server", "state" => "running", "revision" => "abc1234def"},
        %{"service" => "gateway", "state" => "running", "revision" => nil}
      ],
      "checks" => %{
        "api" => %{"ok" => true, "status" => 200, "ms" => 5},
        "site" => %{"ok" => true, "status" => 200, "ms" => 3}
      },
      "disk" => %{"total_kb" => 1000, "used_kb" => 400, "free_kb" => 600},
      "metrics" => %{
        "cpu_percent" => 12.5,
        "cpus" => 4,
        "load" => [0.5, 0.4, 0.3],
        "memory" => %{"total_kb" => 8_000_000, "available_kb" => 6_000_000}
      }
    }
  end
end
