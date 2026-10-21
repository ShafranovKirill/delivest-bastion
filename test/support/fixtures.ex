defmodule Bastion.Fixtures do
  alias Bastion.Instances

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
      "disk" => %{"total_kb" => 1000, "used_kb" => 400, "free_kb" => 600}
    }
  end
end
