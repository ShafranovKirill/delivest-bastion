#!/usr/bin/env bash
# Opt-in recovery drill. Only two newly created local PostgreSQL containers are used.
set -euo pipefail
cd "$(dirname "$0")/.."
umask 077
work=$(mktemp -d -t delivest-bastion-drill.XXXXXXXX)
suffix=${work##*.}
source_db="delivest-bastion-drill-source-$suffix"
target_db="delivest-bastion-drill-target-$suffix"
image=postgres:16-alpine@sha256:0cefaabd882e42bcb2a2f3dc56d3ce4770560ba62fd7f197f1a2e008fd5731ab

remove_db() {
  docker stop "$1" >/dev/null 2>&1 || true
  docker rm -v "$1" >/dev/null 2>&1 || true
}

cleanup() {
  remove_db "$source_db"
  remove_db "$target_db"
  python3 -c 'import shutil, sys; shutil.rmtree(sys.argv[1])' "$work"
}
trap cleanup EXIT

export BASTION_DRILL_DIR="$work" MIX_ENV=test MIX_TEST_PARTITION=stagefour_drill
export TEST_DB_HOST=127.0.0.1
export ERL_FLAGS="${ERL_FLAGS:-+S 4:4}"

start_db() {
  docker run --pull never -d --name "$1" -p 127.0.0.1::5432 \
    -e POSTGRES_PASSWORD=postgres -e POSTGRES_DB=bastion_teststagefour_drill "$image" >/dev/null
  for ((attempt = 0; attempt < 30; attempt++)); do
    if docker exec "$1" pg_isready -h 127.0.0.1 -U postgres >/dev/null 2>&1; then
      TEST_DB_PORT=$(docker port "$1" 5432/tcp | cut -d: -f2)
      export TEST_DB_PORT
      return 0
    fi
    sleep 1
  done
  return 1
}

cat > "$work/probe.exs" <<'ELIXIR'
alias Bastion.{Credentials, Domains, Nodes, Repo}
alias Bastion.Domains.{RegRu, Secrets, ZoneCredential}
alias Bastion.Instances.Instance
alias Bastion.Nodes.Operation

dir = System.fetch_env!("BASTION_DRILL_DIR")
{:ok, _} = Application.ensure_all_started(:ecto_sql)
{:ok, _} = Application.ensure_all_started(:postgrex)
{:ok, _} = Application.ensure_all_started(:phoenix_pubsub)
{:ok, _} = Application.ensure_all_started(:phoenix)
Logger.configure(level: :warning)
base = Application.fetch_env!(:bastion, Repo)
Application.put_env(:bastion, Repo, Keyword.put(base, :pool, DBConnection.ConnectionPool))
Application.put_env(:bastion, :dns_encryption_key, Base.encode64(:binary.copy(<<42>>, 32)))
{:ok, _} = Repo.start_link()
{:ok, _} = Supervisor.start_link([{Phoenix.PubSub, name: Bastion.PubSub}], strategy: :one_for_one)
{:ok, _} = BastionWeb.Endpoint.start_link(server: false)

case System.fetch_env!("BASTION_DRILL_PHASE") do
  "seed" ->
    {:ok, _, _} = Ecto.Migrator.with_repo(Repo, &Ecto.Migrator.run(&1, :up, all: true, log: false))
    {:ok, node, token} = Nodes.create_node("isolated-stage-four")
    {:ok, _, credential} = Nodes.register(token, 1)
    id = Ecto.UUID.generate()
    {:ok, _} =
      Nodes.prepare_instance(node.id, id, "Stage Four Test", %{}, "stage-four-drill", 18080)

    {:ok, domain} =
      Domains.create_domain(%{hostname: "stage-four.example.test", owner: "test", dns_mode: "external"})

    {:ok, binding} = Domains.reserve(domain.id, id, "site", true)
    {:ok, _} = RegRu.save_credentials("example.test", "test", "synthetic DNS value")
    Repo.get!(Instance, id)
    |> Ecto.Changeset.change(
      admin_login: "test",
      admin_password_encrypted: Credentials.encrypt("Synthetic-4-Only!")
    )
    |> Repo.update!()

    {:ok, finished} = Nodes.queue(id, "status", "drill")
    {:ok, _} =
      Nodes.update_operation(node.id, finished.id, "command_result", %{"status" => "ok", "result" => %{}})

    {:ok, pending} = Nodes.queue(id, "stop", "drill")
    {:ok, _} = Nodes.update_operation(node.id, pending.id, "command_ack", %{})
    values = [node.id, credential, id, binding.id, finished.id, pending.id]
    File.write!(Path.join(dir, "expected.json"), Jason.encode!(values))

  "verify" ->
    [node_id, credential, id, binding_id, finished_id, pending_id] =
      File.read!(Path.join(dir, "expected.json")) |> Jason.decode!()

    {:ok, _} = Nodes.authenticate(node_id, credential)
    %{node_id: ^node_id, revision: 1, project_name: "stage-four-drill"} = Nodes.placement_for(id)
    [%{id: ^binding_id, domain: %{hostname: "stage-four.example.test"}}] = Domains.bindings_for(id)
    {:ok, "Synthetic-4-Only!"} =
      Credentials.decrypt(Repo.get!(Instance, id).admin_password_encrypted)

    stored = Repo.get_by!(ZoneCredential, zone: "example.test", provider: "regru")
    {:ok, "synthetic DNS value"} = Secrets.decrypt(stored.secret_ciphertext)
    %{status: "ok"} = Repo.get!(Operation, finished_id)
    [%{id: ^pending_id, placement_revision: 1, status: "running"}] =
      Nodes.pending_operations(node_id)

    {:ok, %{id: ^pending_id, status: "ok"}} =
      Nodes.update_operation(node_id, pending_id, "command_result", %{
        "status" => "ok", "result" => %{"status" => "stopped"}
      })

    [] = Nodes.pending_operations(node_id)
    IO.puts("Bastion recovery verified: registry, placement, domains, protected data and operation history")
end
ELIXIR

start_db "$source_db"
BASTION_DRILL_PHASE=seed mix run --no-start "$work/probe.exs"
docker exec "$source_db" pg_dump -U postgres -Fc bastion_teststagefour_drill > "$work/bastion.dump"
remove_db "$source_db"
start_db "$target_db"
docker exec -i "$target_db" pg_restore --exit-on-error -U postgres -d bastion_teststagefour_drill \
  < "$work/bastion.dump"
BASTION_DRILL_PHASE=verify mix run --no-start "$work/probe.exs"
