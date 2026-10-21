defmodule Bastion.HealthTest do
  use ExUnit.Case, async: true

  alias Bastion.Health
  alias Bastion.Instances.Instance

  @now ~U[2026-10-21 12:00:00Z]

  defp instance(attrs) do
    struct(
      %Instance{
        id: Ecto.UUID.generate(),
        name: "Pizza",
        online: true,
        last_seen_at: ~U[2026-10-21 11:59:50Z],
        status: Bastion.Fixtures.healthy_status(),
        external: %{"api" => %{"ok" => true, "status" => 200}}
      },
      attrs
    )
  end

  test "healthy instance is ok" do
    assert %{level: :ok, problems: []} = Health.evaluate(instance(%{}), @now)
  end

  test "never seen instance has no data" do
    assert %{level: :unknown} = Health.evaluate(instance(%{last_seen_at: nil}), @now)
  end

  test "agent that went away is offline only after the grace period" do
    assert %{level: :ok} = Health.evaluate(instance(%{online: false}), @now)

    assert %{level: :offline} =
             Health.evaluate(
               instance(%{online: false, last_seen_at: ~U[2026-10-21 11:50:00Z]}),
               @now
             )
  end

  test "a planned stop is not an error" do
    status =
      put_in(Bastion.Fixtures.healthy_status(), ["containers"], [
        %{"service" => "server", "state" => "exited"}
      ])

    external = %{"api" => %{"ok" => false, "status" => 502}}

    assert %{level: :stopped, problems: []} =
             Health.evaluate(
               instance(%{status: status, external: external, stopped_at: @now}),
               @now
             )
  end

  test "stopped containers and failed checks are errors" do
    status =
      Bastion.Fixtures.healthy_status()
      |> put_in(["containers"], [%{"service" => "server", "state" => "exited"}])
      |> put_in(["checks", "site"], %{"ok" => false, "status" => 502})

    external = %{"api" => %{"ok" => false, "error" => "timeout"}}

    assert %{level: :down, problems: problems} =
             Health.evaluate(instance(%{status: status, external: external}), @now)

    assert "контейнер server: exited" in problems
    assert "сайт не отвечает изнутри (HTTP 502)" in problems
    assert "API не отвечает снаружи (timeout)" in problems
  end

  test "full disk and expiring certificate are warnings" do
    status =
      put_in(Bastion.Fixtures.healthy_status(), ["disk"], %{"used_kb" => 95, "total_kb" => 100})

    external = %{
      "site" => %{"ok" => true, "status" => 200, "cert_expires_at" => "2026-10-25T00:00:00Z"}
    }

    assert %{
             level: :warning,
             problems: ["диск заполнен на 95%", "сертификат сайт истекает через 3 дн."]
           } =
             Health.evaluate(instance(%{status: status, external: external}), @now)
  end
end
