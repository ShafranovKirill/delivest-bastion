defmodule Bastion.NodeInstallTest do
  use Bastion.DataCase, async: false

  alias Bastion.Nodes
  alias Bastion.Nodes.{Operation, SshInstaller}

  setup do
    Application.put_env(:bastion, :node_ssh_runner, Bastion.FakeNodeSshRunner)
    Application.put_env(:bastion, :ssh_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:bastion, :node_ssh_runner)
      Application.delete_env(:bastion, :ssh_test_pid)
    end)

    :ok
  end

  test "interrupted install is retryable on the same node without stored SSH secrets" do
    params = %{
      "host" => "node.example.org",
      "port" => "22",
      "login" => "root",
      "fingerprint" => "SHA256:" <> String.duplicate("A", 43),
      "password" => "never-store-me"
    }

    assert {:ok, _} = SshInstaller.validate(params)
    assert {:ok, node, operation} = Nodes.start_install("Pilot", params)
    assert_receive {:ssh_started, task, node_id}
    assert node_id == node.id
    assert operation.action == "provision_node"
    assert operation.args == %{}
    refute Nodes.deliverable?(operation)
    assert Nodes.pending_operations(node.id) == []
    assert Nodes.get_node(node.id).ssh_fingerprint == params["fingerprint"]
    refute inspect(Nodes.get_node(node.id)) =~ "never-store-me"
    assert {:error, :install_in_progress} = Nodes.retry_install(Nodes.get_node(node.id), params)
    ref = Process.monitor(task)
    send(task, :continue)
    assert_receive {:DOWN, ^ref, :process, ^task, :normal}
    assert Nodes.get_node(node.id).install_status == "error"
    assert Repo.get(Operation, operation.id).status == "error"

    assert {:ok, retried, second} = Nodes.retry_install(Nodes.get_node(node.id), params)
    assert retried.id == node.id
    refute second.id == operation.id
    assert_receive {:ssh_started, task2, ^node_id}
    ref2 = Process.monitor(task2)
    send(task2, :continue)
    assert_receive {:DOWN, ^ref2, :process, ^task2, :normal}
    assert Repo.get(Operation, second.id).status == "error"
  end

  test "rendered bootstrap verifies the script digest and passes token on stdin" do
    directory =
      Path.join(
        System.tmp_dir!(),
        "node-bootstrap-test-" <> Integer.to_string(System.unique_integer([:positive]))
      )

    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    source = Path.join(directory, "installer.sh")
    output = Path.join(directory, "result")

    File.write!(
      source,
      "#!/bin/sh\nIFS= read -r token\nprintf '%s\\n' \"$token\" > \"$TEST_NODE_TOKEN_OUTPUT\"\nprintf '%s\\n' \"$@\" >> \"$TEST_NODE_TOKEN_OUTPUT\"\n"
    )

    digest = :crypto.hash(:sha256, File.read!(source)) |> Base.encode16(case: :lower)
    fake_curl = Path.join(directory, "curl")

    File.write!(
      fake_curl,
      "#!/bin/sh\nwhile [ \"$#\" -gt 0 ]; do\n  if [ \"$1\" = '-o' ]; then shift; output=$1; fi\n  shift\ndone\ncp \"$TEST_NODE_SCRIPT_SOURCE\" \"$output\"\n"
    )

    File.chmod!(fake_curl, 0o700)

    config = %{
      installer_url: "https://example.org/install'sh",
      installer_sha256: digest,
      archive_url: "https://example.org/archive.tar.gz",
      archive_sha256: String.duplicate("a", 64),
      version: "0.1.0",
      bastion_url: "https://bastion.example.org",
      cert_email: "tls@example.org"
    }

    command = SshInstaller.bootstrap_command(%{id: Ecto.UUID.generate()}, config, "root")

    {stdout, status} =
      System.cmd("bash", ["-c", "printf '%s\\n' 'one-time-test-token' | ( " <> command <> " )"],
        env: [
          {"PATH", directory <> ":" <> System.get_env("PATH")},
          {"TEST_NODE_SCRIPT_SOURCE", source},
          {"TEST_NODE_TOKEN_OUTPUT", output}
        ],
        stderr_to_stdout: true
      )

    assert status == 0, stdout
    [token | args] = String.split(File.read!(output), "\n", trim: true)
    assert token == "one-time-test-token"
    assert "--node-id" in args
    refute "one-time-test-token" in args
  end

  test "an orphaned SSH task is marked unknown and can be retried" do
    params = %{
      "host" => "orphan.example.org",
      "port" => "22",
      "login" => "root",
      "fingerprint" => "SHA256:" <> String.duplicate("C", 43),
      "private_key" => "test-key"
    }

    assert {:ok, node, operation} = Nodes.start_install("Orphan", params)
    assert_receive {:ssh_started, task, _}
    ref = Process.monitor(task)
    Process.exit(task, :kill)
    assert_receive {:DOWN, ^ref, :process, ^task, :killed}
    Nodes.recover_interrupted_installs()
    assert Repo.get(Operation, operation.id).status == "unknown"
    assert Nodes.get_node(node.id).install_status == "interrupted"
    assert {:ok, same, retry} = Nodes.retry_install(Nodes.get_node(node.id), params)
    assert same.id == node.id
    refute retry.id == operation.id
    assert_receive {:ssh_started, task2, _}
    ref2 = Process.monitor(task2)
    send(task2, :continue)
    assert_receive {:DOWN, ^ref2, :process, ^task2, :normal}
  end

  test "startup cleanup removes only owned private SSH credential directories" do
    suffix = fn -> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower) end
    stale = Path.join(System.tmp_dir!(), "delivest-node-ssh-" <> suffix.())
    unrelated = Path.join(System.tmp_dir!(), "other-node-ssh-" <> suffix.())
    linked = Path.join(System.tmp_dir!(), "delivest-node-ssh-" <> suffix.())

    File.mkdir!(stale)
    File.chmod!(stale, 0o700)
    File.write!(Path.join(stale, "password"), "temporary-secret")
    File.mkdir!(unrelated)
    File.write!(Path.join(unrelated, "keep"), "neighbor")
    File.ln_s!(unrelated, linked)

    on_exit(fn ->
      File.rm_rf(stale)
      File.rm_rf(unrelated)
      File.rm(linked)
    end)

    assert :ok = SshInstaller.cleanup_stale_credentials()
    refute File.exists?(stale)
    assert File.read!(Path.join(unrelated, "keep")) == "neighbor"
    assert {:ok, %{type: :symlink}} = File.lstat(linked)
  end

  test "SSH credential guardian removes private files when the install task is killed" do
    parent = self()

    {:ok, owner} =
      Task.Supervisor.start_child(Bastion.TaskSupervisor, fn ->
        {directory, guardian} = SshInstaller.guarded_directory()
        File.write!(Path.join(directory, "password"), "temporary-secret")
        send(parent, {:private_directory, directory, guardian})

        receive do
          :wait -> :ok
        end
      end)

    assert_receive {:private_directory, directory, guardian}
    assert File.exists?(Path.join(directory, "password"))
    on_exit(fn -> File.rm_rf(directory) end)
    guardian_ref = Process.monitor(guardian)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^guardian_ref, :process, ^guardian, :normal}, 1_000
    refute File.exists?(directory)
  end
end
