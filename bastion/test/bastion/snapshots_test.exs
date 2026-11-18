defmodule Bastion.SnapshotsTest do
  use BastionWeb.ConnCase, async: false
  use Oban.Testing, repo: Bastion.Repo

  import Bastion.Fixtures
  import Phoenix.LiveViewTest

  alias Bastion.{Backups, Instances, Repo, Snapshots}
  alias Bastion.Snapshots.{Archive, Snapshot, Verifier}
  alias BastionWeb.Presence

  setup do
    test_pid = self()
    directory = Path.join(System.tmp_dir!(), "bastion-snapshots-test-#{Ecto.UUID.generate()}")
    File.mkdir_p!(directory)
    script = Path.join(directory, "pg_restore")
    File.write!(script, "#!/bin/sh\nexit 0\n")
    File.chmod!(script, 0o700)
    old_pg_restore = Application.get_env(:bastion, :pg_restore)
    Application.put_env(:bastion, :pg_restore, script)

    on_exit(fn ->
      if old_pg_restore,
        do: Application.put_env(:bastion, :pg_restore, old_pg_restore),
        else: Application.delete_env(:bastion, :pg_restore)

      File.rm_rf!(directory)
    end)

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
      send(test_pid, {:s3, conn.method, conn.request_path, body})

      case conn.method do
        "GET" -> Plug.Conn.send_resp(conn, 200, "full-archive")
        "DELETE" -> Plug.Conn.send_resp(conn, 204, "")
        _ -> Plug.Conn.send_resp(conn, 200, "")
      end
    end)

    {:ok, directory: directory}
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
    Instances.get_instance(instance.id)
  end

  defp archive(directory, suffix) do
    work = Path.join(directory, suffix)
    File.mkdir_p!(Path.join(work, "data"))
    File.write!(Path.join([work, "data", "photo"]), "original")
    {_, 0} = System.cmd("tar", ["-C", work, "-cf", Path.join(work, "storage.tar"), "data"])
    File.write!(Path.join(work, "database.dump"), "PGDMP-data")
    {:ok, db} = Archive.digest(Path.join(work, "database.dump"))
    {:ok, storage} = Archive.digest(Path.join(work, "storage.tar"))

    File.write!(
      Path.join(work, "manifest.json"),
      Jason.encode!(%{
        format: "delivest-full",
        version: 1,
        files: %{database_dump: db, storage_tar: storage}
      })
    )

    path = Path.join(directory, "#{suffix}.tar")
    :ok = Archive.create(work, path)
    path
  end

  defp start_snapshot(instance) do
    assert {:ok, snapshot} = Snapshots.start(instance, "admin")
    assert_receive {:agent_got, %{action: "full_backup", args: args}}
    {snapshot, args}
  end

  defp upload(conn, args, path) do
    conn
    |> put_req_header("authorization", "Bearer " <> args["token"])
    |> put_req_header("content-type", "application/octet-stream")
    |> put(URI.parse(args["upload_url"]).path, File.read!(path))
  end

  test "full archive command hides the upload token and refuses a parallel export", %{
    directory: directory
  } do
    instance = instance_fixture() |> bring_online()
    {snapshot, args} = start_snapshot(instance)

    assert args["upload_url"] =~ "/agent/backups/snapshots/#{snapshot.id}"
    assert is_binary(args["token"])
    [command] = Instances.list_commands(instance.id)
    refute Map.has_key?(command.args, "token")
    assert {:error, :busy} = Snapshots.start(instance, "admin")
    assert %{status: "pending"} = Repo.get!(Snapshot, snapshot.id)

    path = archive(directory, "first")
    assert :ok = Verifier.run(path)
  end

  test "a checked upload becomes downloadable and replay is rejected", %{
    conn: conn,
    directory: directory
  } do
    instance = instance_fixture() |> bring_online()
    {snapshot, args} = start_snapshot(instance)
    path = archive(directory, "good")

    assert conn |> upload(args, path) |> json_response(200) == %{
             "ok" => true,
             "size" => File.stat!(path).size
           }

    assert %{id: id, status: "ok"} = Snapshots.latest(instance.id)
    assert id == snapshot.id
    assert build_conn() |> upload(args, path) |> json_response(403)

    assert redirected_to(get(build_conn(), ~p"/backups/snapshots/#{id}/download")) == ~p"/login"

    download =
      build_conn()
      |> init_test_session(%{"admin" => "admin"})
      |> get(~p"/backups/snapshots/#{id}/download")

    assert response(download, 200) == "full-archive"
    assert [disposition] = get_resp_header(download, "content-disposition")
    assert disposition =~ "full.tar"
    assert Repo.aggregate(Bastion.Backups.Backup, :count, :id) == 0
  end

  test "bad replacement preserves the previous complete archive", %{directory: directory} do
    instance = instance_fixture() |> bring_online()
    {first, args} = start_snapshot(instance)
    assert build_conn() |> upload(args, archive(directory, "first")) |> json_response(200)

    {:ok, _} =
      Instances.command_finished(
        instance.id,
        Repo.get!(Snapshot, first.id).command_id,
        true,
        "done"
      )

    {second, args} = start_snapshot(Instances.get_instance(instance.id))
    bad = Path.join(directory, "bad.tar")
    File.write!(bad, "not an archive")
    assert build_conn() |> upload(args, bad) |> json_response(502)
    assert Snapshots.latest(instance.id).id == first.id
    assert Repo.get!(Snapshot, second.id).status == "error"
    refute_received {:s3, "DELETE", _, _}
  end

  test "a matching tar with altered contents is rejected before storage", %{directory: directory} do
    instance = instance_fixture() |> bring_online()
    {snapshot, args} = start_snapshot(instance)
    path = archive(directory, "tampered")
    work = Path.join(directory, "tampered")
    File.write!(Path.join(work, "database.dump"), "PGDMP-changed")
    :ok = Archive.create(work, path)

    assert build_conn() |> upload(args, path) |> json_response(502)
    assert Repo.get!(Snapshot, snapshot.id).status == "error"
    assert Snapshots.latest(instance.id) == nil
    refute_received {:s3, "PUT", "/backups/snapshots/" <> _, _}
  end

  test "a failed storage upload keeps the preceding usable snapshot", %{directory: directory} do
    instance = instance_fixture() |> bring_online()
    {first, args} = start_snapshot(instance)
    assert build_conn() |> upload(args, archive(directory, "first")) |> json_response(200)

    {:ok, _} =
      Instances.command_finished(
        instance.id,
        Repo.get!(Snapshot, first.id).command_id,
        true,
        "done"
      )

    test_pid = self()

    Req.Test.stub(Bastion.Http, fn conn ->
      {:ok, _body, conn} = Plug.Conn.read_body(conn, length: 100_000_000)
      send(test_pid, {:storage_attempt, conn.method, conn.request_path})

      if conn.method == "PUT" and String.starts_with?(conn.request_path, "/backups/snapshots/") do
        Plug.Conn.send_resp(conn, 503, "unavailable")
      else
        Plug.Conn.send_resp(conn, 204, "")
      end
    end)

    {second, args} = start_snapshot(Instances.get_instance(instance.id))
    assert build_conn() |> upload(args, archive(directory, "second")) |> json_response(502)
    assert Snapshots.latest(instance.id).id == first.id
    assert Repo.get!(Snapshot, second.id).status == "error"
    first_path = "/backups/" <> first.key
    refute_received {:storage_attempt, "DELETE", ^first_path}
  end

  test "successful replacement removes the former full archive, not database backups", %{
    directory: directory
  } do
    instance = instance_fixture() |> bring_online()
    {first, args} = start_snapshot(instance)
    assert build_conn() |> upload(args, archive(directory, "first")) |> json_response(200)

    {:ok, _} =
      Instances.command_finished(
        instance.id,
        Repo.get!(Snapshot, first.id).command_id,
        true,
        "done"
      )

    {second, args} = start_snapshot(Instances.get_instance(instance.id))
    assert build_conn() |> upload(args, archive(directory, "second")) |> json_response(200)
    assert Snapshots.latest(instance.id).id == second.id
    assert Repo.get(Snapshot, first.id) == nil
    assert_received {:s3, "DELETE", _path, _body}
    assert Backups.list(instance.id) == []
  end

  test "admin page shows latest archive and offers a manual snapshot", %{
    conn: conn,
    directory: directory
  } do
    instance = instance_fixture() |> bring_online()

    {:ok, lv, _} =
      live(
        init_test_session(conn, %{"admin" => "admin"}),
        ~p"/instances/#{instance.id}?tab=backups"
      )

    assert has_element?(lv, "#snapshot-empty")
    assert has_element?(lv, "#snapshot-now")

    {snapshot, args} = start_snapshot(instance)
    assert build_conn() |> upload(args, archive(directory, "ui")) |> json_response(200)

    assert has_element?(
             lv,
             "#snapshot-download[href='/backups/snapshots/#{snapshot.id}/download']"
           )
  end

  test "daily scheduling queues each supported instance and skips one already completed today", %{
    directory: directory
  } do
    instance = instance_fixture() |> bring_online()
    assert :ok = Snapshots.run_daily()
    assert_enqueued(worker: Bastion.Snapshots.Worker, args: %{instance_id: instance.id})

    {snapshot, args} = start_snapshot(instance)
    assert build_conn() |> upload(args, archive(directory, "daily")) |> json_response(200)

    {:ok, _} =
      Instances.command_finished(
        instance.id,
        Repo.get!(Snapshot, snapshot.id).command_id,
        true,
        "done"
      )

    assert :ok =
             Bastion.Snapshots.Worker.perform(%Oban.Job{args: %{"instance_id" => instance.id}})

    refute_receive {:agent_got, _}
  end

  test "a late agent upload cannot revive a failed snapshot", %{directory: directory} do
    instance = instance_fixture() |> bring_online()
    {snapshot, args} = start_snapshot(instance)

    {:ok, command} =
      Instances.command_finished(
        instance.id,
        Repo.get!(Snapshot, snapshot.id).command_id,
        false,
        "failed"
      )

    Snapshots.command_finished(command)

    assert Repo.get!(Snapshot, snapshot.id).status == "error"
    assert build_conn() |> upload(args, archive(directory, "late")) |> json_response(403)
  end
end
