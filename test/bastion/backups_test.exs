defmodule Bastion.BackupsTest do
  use BastionWeb.ConnCase, async: false

  import Bastion.Fixtures

  alias Bastion.{Backups, Instances, Repo}
  alias Bastion.Backups.Backup
  alias BastionWeb.Presence

  setup do
    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
      send(test_pid, {:s3, conn.method, conn.request_path, body})

      case {conn.method, conn.request_path} do
        {"GET", _path} -> Plug.Conn.send_resp(conn, 200, "PGDMP-stored")
        {"DELETE", _path} -> Plug.Conn.send_resp(conn, 204, "")
        _ -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    :ok
  end

  defp bring_online(instance) do
    test_pid = self()

    spawn_link(fn ->
      Instances.subscribe_commands(instance.id)
      {:ok, _} = Presence.track_agent(self(), instance.id)
      send(test_pid, :online)

      loop = fn loop ->
        receive do
          {:push_command, command} -> send(test_pid, {:agent_got, command})
        end

        loop.(loop)
      end

      loop.(loop)
    end)

    assert_receive :online
    instance
  end

  defp start_backup(instance) do
    assert {:ok, backup} = Backups.start(instance, "admin")
    assert_receive {:agent_got, %{action: "backup", args: args}}
    {backup, args}
  end

  defp upload(conn, args, body \\ "PGDMP-data") do
    conn
    |> put_req_header("authorization", "Bearer " <> args["token"])
    |> put_req_header("content-type", "application/octet-stream")
    |> put(URI.parse(args["upload_url"]).path, body)
  end

  test "the agent gets an upload url and a token that is not stored" do
    instance = instance_fixture() |> bring_online()
    {backup, args} = start_backup(instance)

    assert args["upload_url"] =~ "/agent/backups/#{backup.id}"
    assert is_binary(args["token"])

    [command] = Instances.list_commands(instance.id)
    assert command.action == "backup"
    refute Map.has_key?(command.args, "token")
    assert Repo.get!(Backup, backup.id).command_id == command.id
  end

  test "the upload goes to the storage and marks the backup done", %{conn: conn} do
    instance = instance_fixture() |> bring_online()
    {backup, args} = start_backup(instance)

    assert %{"ok" => true, "size" => 10} = conn |> upload(args) |> json_response(200)

    key = Repo.get!(Backup, backup.id).key
    assert_received {:s3, "PUT", "/backups/" <> ^key, "PGDMP-data"}
    assert %{status: "ok", size: 10} = Repo.get!(Backup, backup.id)
  end

  test "uploads need the right token and only once", %{conn: conn} do
    instance = instance_fixture() |> bring_online()
    {_backup, args} = start_backup(instance)

    assert conn |> upload(%{args | "token" => "forged"}) |> json_response(403)
    assert build_conn() |> upload(args) |> json_response(200)
    assert build_conn() |> upload(args) |> json_response(403)
  end

  test "only the last backups are kept", %{conn: _conn} do
    instance = instance_fixture() |> bring_online()

    for _ <- 1..9 do
      {_backup, args} = start_backup(instance)
      build_conn() |> upload(args) |> json_response(200)
    end

    assert Backup |> Repo.all() |> Enum.count(&(&1.status == "ok")) == Backups.keep()
    assert_received {:s3, "DELETE", _path, _body}
  end

  test "an agent error fails the backup" do
    instance = instance_fixture() |> bring_online()
    {backup, _args} = start_backup(instance)
    command = Repo.get!(Backup, backup.id).command_id

    {:ok, command} =
      Instances.command_finished(
        instance.id,
        command,
        false,
        "== dump database failed\npg_dump: error"
      )

    Backups.command_finished(command)

    assert %{status: "error", error: error} = Repo.get!(Backup, backup.id)
    assert error =~ "pg_dump: error"
  end

  test "an offline agent and an old agent give a failed backup" do
    assert {:error, "агент не на связи"} = Backups.start(instance_fixture())

    old = instance_fixture(%{info: %{"actions" => ["status", "update"]}}) |> bring_online()
    assert {:error, "агент не умеет" <> _} = Backups.start(old)
    assert Backup |> Repo.all() |> Enum.all?(&(&1.status == "error"))
  end

  test "restore gives the agent a download link that works", %{conn: conn} do
    source = instance_fixture() |> bring_online()
    {backup, args} = start_backup(source)
    build_conn() |> upload(args) |> json_response(200)

    target = instance_fixture() |> bring_online()
    assert {:ok, _command} = Backups.restore(target, Repo.get!(Backup, backup.id), "admin")
    assert_receive {:agent_got, %{action: "restore", args: restore}}

    assert restore["backup_id"] == backup.id

    file =
      conn
      |> put_req_header("authorization", "Bearer " <> restore["token"])
      |> get(URI.parse(restore["download_url"]).path)

    assert response(file, 200) == "PGDMP-stored"

    assert build_conn()
           |> put_req_header("authorization", "Bearer " <> args["token"])
           |> get(URI.parse(restore["download_url"]).path)
           |> json_response(403)
  end

  test "admins download a backup with a readable name", %{conn: conn} do
    instance = instance_fixture(%{info: %{"name" => "Пицца Север"}}) |> bring_online()
    {backup, args} = start_backup(instance)
    build_conn() |> upload(args) |> json_response(200)

    assert redirected_to(get(conn, ~p"/backups/#{backup.id}/download")) == ~p"/login"

    download =
      conn
      |> init_test_session(%{"admin" => "admin"})
      |> get(~p"/backups/#{backup.id}/download")

    assert response(download, 200) == "PGDMP-stored"
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert disposition =~ URI.encode("Пицца-Север")
  end

  test "backups of a deleted instance stay restorable" do
    instance = instance_fixture() |> bring_online()
    {backup, args} = start_backup(instance)
    build_conn() |> upload(args) |> json_response(200)

    {:ok, _} = Instances.delete_instance(Instances.get_instance(instance.id))

    assert [%{id: id, instance_id: nil}] = Backups.list_restorable()
    assert id == backup.id
  end
end
