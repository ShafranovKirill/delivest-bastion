defmodule Bastion.Nodes.SshInstaller do
  @moduledoc "Pinned-host SSH bootstrap for one Node installation attempt."
  import Bitwise, only: [band: 2]

  @host ~r/\A(?:[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}|[0-9a-fA-F:]+)\z/
  @login ~r/\A[a-z_][a-z0-9_-]{0,31}\z/
  @fingerprint ~r/\ASHA256:[A-Za-z0-9+\/]{43}\z/

  def validate(attrs) do
    with host when is_binary(host) <- attrs["host"],
         true <- Regex.match?(@host, host),
         {port, ""} <- Integer.parse(to_string(attrs["port"] || "")),
         true <- port in 1..65_535,
         login when is_binary(login) <- attrs["login"],
         true <- Regex.match?(@login, login),
         fingerprint when is_binary(fingerprint) <- attrs["fingerprint"],
         true <- Regex.match?(@fingerprint, fingerprint),
         true <-
           (is_binary(attrs["password"]) and attrs["password"] != "") or
             (is_binary(attrs["private_key"]) and attrs["private_key"] != "") do
      {:ok,
       %{
         host: host,
         port: port,
         login: login,
         fingerprint: fingerprint,
         password: attrs["password"],
         private_key: attrs["private_key"]
       }}
    else
      _ -> {:error, :invalid_ssh_parameters}
    end
  end

  def install(node, token, attrs) do
    runner = Application.get_env(:bastion, :node_ssh_runner, __MODULE__)
    runner.run(node, token, attrs)
  end

  @doc false
  def cleanup_stale_credentials do
    directory = System.tmp_dir!()
    {uid, 0} = System.cmd("id", ["-u"])
    owner_uid = uid |> String.trim() |> String.to_integer()

    with {:ok, entries} <- File.ls(directory) do
      Enum.each(entries, fn entry ->
        if String.match?(entry, ~r/\Adelivest-node-ssh-[0-9a-f]{24}\z/) do
          path = Path.join(directory, entry)

          case File.lstat(path) do
            {:ok, %{type: :directory, uid: ^owner_uid, mode: mode}}
            when band(mode, 0o077) == 0 ->
              File.rm_rf(path)

            _ ->
              :ok
          end
        end
      end)
    end

    :ok
  end

  def run(node, token, attrs) do
    with {:ok, ssh} <- validate(attrs),
         {:ok, config} <- installer_config(),
         {:ok, keyline} <- pinned_host_key(ssh) do
      {directory, guardian} = guarded_directory()

      try do
        known_hosts = private_file(directory, "known_hosts", keyline <> "\n")
        {program, prefix} = credentials(directory, ssh)

        ssh_args =
          prefix ++
            [
              "-F",
              "/dev/null",
              "-o",
              "BatchMode=#{if ssh.password, do: "no", else: "yes"}",
              "-o",
              "StrictHostKeyChecking=yes",
              "-o",
              "UserKnownHostsFile=#{known_hosts}",
              "-o",
              "GlobalKnownHostsFile=/dev/null",
              "-o",
              "ConnectTimeout=10",
              "-o",
              "ForwardAgent=no",
              "-o",
              "ForwardX11=no",
              "-o",
              "PermitLocalCommand=no",
              "-p",
              to_string(ssh.port),
              "#{ssh.login}@#{ssh.host}"
            ]

        with :ok <-
               remote(
                 program,
                 ssh_args,
                 if(ssh.login == "root", do: "id -u | grep -qx 0", else: "sudo -n true"),
                 ""
               ),
             :ok <-
               remote(
                 program,
                 ssh_args,
                 bootstrap_command(node, config, ssh.login),
                 token <> "\n",
                 node.id
               ) do
          :ok
        end
      after
        File.rm_rf(directory)
        send(guardian, :done)
      end
    end
  end

  @doc false
  def guarded_directory do
    directory =
      Path.join(
        System.tmp_dir!(),
        "delivest-node-ssh-" <> Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      )

    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    owner = self()

    try do
      {:ok, guardian} =
        Task.Supervisor.start_child(Bastion.TaskSupervisor, fn ->
          ref = Process.monitor(owner)

          receive do
            :done -> :ok
            {:DOWN, ^ref, :process, ^owner, _reason} -> File.rm_rf(directory)
          end
        end)

      {directory, guardian}
    rescue
      error ->
        File.rm_rf(directory)
        reraise(error, __STACKTRACE__)
    end
  end

  defp installer_config do
    config = Application.get_env(:bastion, :node_installer, %{})

    required =
      ~w(installer_url installer_sha256 archive_url archive_sha256 version bastion_url cert_email)a

    if Enum.all?(required, &(is_binary(config[&1]) and config[&1] != "")) and
         Enum.all?(
           [:installer_sha256, :archive_sha256],
           &String.match?(config[&1], ~r/\A[0-9a-fA-F]{64}\z/)
         ) and
         Enum.all?(
           [:installer_url, :archive_url, :bastion_url],
           &String.starts_with?(config[&1], "https://")
         ) do
      {:ok, config}
    else
      {:error, :installer_not_configured}
    end
  end

  defp pinned_host_key(%{host: host, port: port, fingerprint: fingerprint}) do
    case System.cmd("ssh-keyscan", ["-T", "10", "-p", to_string(port), "-t", "ed25519", host],
           stderr_to_stdout: false
         ) do
      {output, 0} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.find_value(fn line ->
          case String.split(line, " ", parts: 3) do
            [_hostname, "ssh-ed25519", encoded] ->
              with {:ok, key} <- Base.decode64(encoded),
                   actual <-
                     "SHA256:" <> Base.encode64(:crypto.hash(:sha256, key), padding: false),
                   true <- Plug.Crypto.secure_compare(actual, fingerprint),
                   do: line

            _ ->
              nil
          end
        end)
        |> case do
          nil -> {:error, :ssh_host_identity_mismatch}
          line -> {:ok, line}
        end

      _ ->
        {:error, :ssh_host_unreachable}
    end
  end

  defp credentials(directory, %{private_key: key}) when is_binary(key) and key != "" do
    path = private_file(directory, "identity", key)
    {"ssh", ["-i", path, "-o", "IdentitiesOnly=yes"]}
  end

  defp credentials(directory, %{password: password}) when is_binary(password) do
    path = private_file(directory, "password", password <> "\n")
    {"sshpass", ["-f", path, "ssh"]}
  end

  defp private_file(directory, name, data) do
    path = Path.join(directory, name)
    :ok = File.write(path, data, [:binary, :exclusive])
    :ok = File.chmod(path, 0o600)
    path
  end

  @doc false
  def bootstrap_command(node, config, login) do
    script = "$stage/install.sh"

    [
      "umask 077",
      "stage=$(mktemp -d)",
      "trap 'rm -rf \"$stage\"' EXIT",
      "curl --proto '=https' --tlsv1.2 -fsSL " <> q(config.installer_url) <> " -o " <> script,
      "printf '%s  %s" <>
        <<92, 110>> <>
        "' " <> q(config.installer_sha256) <> " " <> script <> " | sha256sum -c - >/dev/null",
      "chmod 700 " <> script,
      if(login == "root", do: "", else: "sudo -n ") <>
        script <>
        " --node-id " <>
        q(node.id) <>
        " --archive-url " <>
        q(config.archive_url) <>
        " --archive-sha256 " <>
        q(config.archive_sha256) <>
        " --version " <>
        q(config.version) <>
        " --bastion-url " <>
        q(config.bastion_url) <>
        " --cert-email " <> q(config.cert_email),
      "true"
    ]
    |> Enum.join("; ")
    |> then(&("set -e; " <> &1))
  end

  defp q(value), do: "'" <> String.replace(value, "'", "'\"'\"'") <> "'"

  defp remote(program, args, command, input, node_id \\ nil) do
    case System.find_executable(program) do
      nil ->
        {:error, :ssh_client_missing}

      executable ->
        port =
          Port.open({:spawn_executable, executable}, [
            :binary,
            :exit_status,
            :hide,
            args: args ++ [command]
          ])

        if input != "", do: Port.command(port, input)
        receive_result(port, System.monotonic_time(:millisecond) + 1_200_000, node_id)
    end
  end

  defp receive_result(port, deadline, node_id) do
    remaining = max(0, deadline - System.monotonic_time(:millisecond))

    receive do
      {^port, {:data, output}} ->
        if node_id do
          for [_, stage] <-
                Regex.scan(
                  ~r/STAGE=(preflight|download|packages|release|systemd|registration|ready)/,
                  output
                ) do
            Bastion.Nodes.install_stage(node_id, stage)
          end
        end

        receive_result(port, deadline, node_id)

      {^port, {:exit_status, 0}} ->
        :ok

      {^port, {:exit_status, _}} ->
        {:error, :remote_install_failed}
    after
      remaining ->
        Port.close(port)
        {:error, :ssh_timeout}
    end
  end
end
