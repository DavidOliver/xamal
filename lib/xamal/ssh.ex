defmodule Xamal.SSH do
  @moduledoc """
  High-level SSH API for executing commands on remote hosts.

  Provides `on/2` and `on_roles/3` for parallel execution across hosts.
  Uses Erlang's `:ssh` stdlib under the hood via ConnectionPool.
  """

  alias Xamal.Configuration.{Boot, Ssh}
  alias Xamal.SSH.{ConnectionPool, Host, Proxy, Runner}

  require Record
  Record.defrecordp(:file_info, Record.extract(:file_info, from_lib: "kernel/include/file.hrl"))

  @doc """
  Execute a function on each host in parallel.
  Returns list of {host, result} tuples.
  """
  def on(hosts, fun) when is_list(hosts) do
    Runner.run(hosts, fun)
  end

  @doc """
  Execute on hosts grouped by role, with configurable parallelism.
  """
  def on_roles(roles, config, fun, opts \\ []) do
    if parallel_roles?(config.boot, opts) do
      Enum.flat_map(roles, &run_role(&1, fun))
    else
      Enum.flat_map(roles, &run_role(&1, fun, config.boot))
    end
  end

  defp parallel_roles?(boot, opts) do
    Keyword.get(opts, :parallel, false) and boot.parallel_roles
  end

  defp run_role(role, fun) do
    on(role.hosts, fn host -> fun.(host, role) end)
  end

  defp run_role(role, fun, boot) do
    Runner.run(role.hosts, fn host -> fun.(host, role) end,
      concurrency: Boot.resolved_limit(boot, length(role.hosts)),
      wait: boot.wait
    )
  end

  @doc """
  Execute a shell command string on a remote host.
  Returns {:ok, output} or {:error, reason}.

  Uses Erlang's `:ssh` by default; shells out to the system `ssh` binary
  instead when `ssh.system_ssh` is set (see `Xamal.Configuration.Ssh`).
  """
  def execute(host, command, opts \\ []) when is_binary(command) do
    ssh_config = Keyword.get(opts, :ssh_config, %Ssh{})

    if ssh_config.system_ssh do
      execute_via_system_ssh(host, command, ssh_config)
    else
      execute_via_erlang_ssh(host, command, ssh_config, opts)
    end
  end

  defp execute_via_erlang_ssh(host, command, ssh_config, opts) do
    timeout = Keyword.get(opts, :timeout, 30_000)
    hostname = Host.hostname(host)
    port = Host.port(host, ssh_config)

    checkout_result =
      ConnectionPool.checkout(
        hostname,
        port,
        ssh_config.user,
        Ssh.connect_options(ssh_config)
      )

    with {:ok, conn} <- checkout_result do
      try do
        exec_command(conn, command, timeout)
      after
        ConnectionPool.checkin(hostname, port, ssh_config.user)
      end
    end
  end

  defp execute_via_system_ssh(host, command, ssh_config) do
    args = system_ssh_args(ssh_config, Host.hostname(host), Host.port(host, ssh_config))

    case System.cmd("ssh", args ++ [command], stderr_to_stdout: true) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit_status, code, output}}
    end
  end

  @doc """
  The argument list for a system `ssh` call with `ssh.system_ssh`, up to and
  including the `user@host` destination; the caller appends the command.

  `ssh_flags/2` plus what only applies when every connection goes through the
  system binary: `-F /dev/null` for `ssh.config: false`, and `ConnectTimeout`
  from `ssh.connect_timeout`.
  """
  def system_ssh_args(ssh_config, hostname, port) do
    ssh_flags(ssh_config, port) ++
      system_only_flags(ssh_config) ++ ["#{ssh_config.user}@#{hostname}"]
  end

  defp system_only_flags(ssh_config) do
    config = if ssh_config.config == false, do: ["-F", "/dev/null"], else: []

    timeout =
      case ssh_config.connect_timeout do
        ms when is_integer(ms) -> ["-o", "ConnectTimeout=#{max(div(ms, 1000), 1)}"]
        _ -> []
      end

    config ++ timeout
  end

  @doc """
  The argument list for a system `scp` call with `ssh.system_ssh`.
  `remote_path` is `user@host:path`, as either source or destination.
  """
  def system_scp_args(ssh_config, port, source, destination) do
    scp_flags(ssh_config, port) ++ system_only_flags(ssh_config) ++ [source, destination]
  end

  defp system_scp(ssh_config, port, source, destination) do
    case System.cmd("scp", system_scp_args(ssh_config, port, source, destination),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {output, code} -> {:error, {:scp_failed, code, String.trim(output)}}
    end
  end

  defp scp_remote(ssh_config, hostname, remote_path),
    do: "#{ssh_config.user}@#{hostname}:#{sftp_path(remote_path)}"

  @doc """
  Upload a file to a remote host.

  When an on-disk private key is configured (`ssh.keys`), this shells out to the
  system `scp` binary, which transfers at full link speed. Erlang's built-in
  `:ssh_sftp` writes the whole file through a small SFTP window (~100-200 KB/s in
  practice), which is pathologically slow for release tarballs (hundreds of MB) —
  a multi-minute upload becomes seconds over scp. When no key file is available
  (e.g. `key_data` from a secrets manager, or an agent), it falls back to the
  in-VM SFTP channel so those flows keep working.
  """
  def upload(host, local_path, remote_path, opts \\ []) do
    ssh_config = Keyword.get(opts, :ssh_config, %Ssh{})
    hostname = Host.hostname(host)
    port = Host.port(host, ssh_config)

    # Use scp only when both an on-disk key and the scp binary are available.
    # A missing scp binary falls back to SFTP instead of raising :enoent, so
    # the upload still succeeds (just slower) and the contract is preserved.
    # system_ssh always uses scp: SFTP over Erlang's :ssh can't use the agent.
    case upload_transport(ssh_config) do
      :system_ssh ->
        with :ok <-
               system_scp(
                 ssh_config,
                 port,
                 local_path,
                 scp_remote(ssh_config, hostname, remote_path)
               ),
             do: {:ok, remote_path}

      {:ok, key_path} ->
        if scp_available?() do
          upload_via_scp(key_path, ssh_config, hostname, port, local_path, remote_path)
        else
          write_via_sftp_pooled(
            ssh_config,
            hostname,
            port,
            File.read!(local_path),
            remote_path,
            []
          )
        end

      :none ->
        write_via_sftp_pooled(ssh_config, hostname, port, File.read!(local_path), remote_path, [])
    end
  end

  @doc """
  Write `content` to `remote_path` over SFTP.

  The content never appears on a command line, so use this for anything
  secret, such as env files. A command like `echo '...' > file` shows its
  arguments in the server's process list.

  Options: `:mode` sets the file mode before the content is written, so the
  content is never readable with looser permissions; `:timeout` (default
  30s) bounds each SFTP operation.
  """
  def write_file(host, content, remote_path, opts \\ []) do
    ssh_config = Keyword.get(opts, :ssh_config, %Ssh{})
    hostname = Host.hostname(host)
    port = Host.port(host, ssh_config)
    sftp_opts = [mode: Keyword.get(opts, :mode), timeout: Keyword.get(opts, :timeout, 30_000)]

    if ssh_config.system_ssh do
      write_via_system_scp(host, ssh_config, content, remote_path, Keyword.get(opts, :mode))
    else
      write_via_sftp_pooled(ssh_config, hostname, port, content, remote_path, sftp_opts)
    end
  end

  # With system_ssh there is no SFTP channel to set the mode on before the
  # content arrives, so create the file (or tighten an existing one) with the
  # mode first, then scp over it: scp keeps an existing file's mode. The
  # content goes through a local file in a 0700 directory, never a command line.
  defp write_via_system_scp(host, ssh_config, content, remote_path, mode) do
    hostname = Host.hostname(host)
    port = Host.port(host, ssh_config)
    dir = Path.join(System.tmp_dir!(), "xamal-#{System.unique_integer([:positive])}")
    local_path = Path.join(dir, Path.basename(remote_path))

    try do
      with :ok <- File.mkdir_p(dir),
           :ok <- File.chmod(dir, 0o700),
           :ok <- File.write(local_path, content),
           :ok <- File.chmod(local_path, mode || 0o600),
           {:ok, _} <- prepare_remote_mode(host, remote_path, mode, ssh_config),
           :ok <-
             system_scp(
               ssh_config,
               port,
               local_path,
               scp_remote(ssh_config, hostname, remote_path)
             ) do
        {:ok, remote_path}
      else
        {:error, reason} -> {:error, {:scp_write_failed, remote_path, reason}}
      end
    after
      File.rm_rf(dir)
    end
  end

  defp prepare_remote_mode(_host, _remote_path, nil, _ssh_config), do: {:ok, ""}

  defp prepare_remote_mode(host, remote_path, mode, ssh_config) do
    path = Xamal.Utils.shell_escape(remote_path)
    octal = Integer.to_string(mode, 8)

    execute_via_system_ssh(
      host,
      "(umask 077 && : >> #{path}) && chmod #{octal} #{path}",
      ssh_config
    )
  end

  defp upload_transport(%Ssh{system_ssh: true}), do: :system_ssh
  defp upload_transport(ssh_config), do: key_file(ssh_config)

  defp scp_available?, do: System.find_executable("scp") != nil

  defp write_via_sftp_pooled(ssh_config, hostname, port, content, remote_path, sftp_opts) do
    checkout_result =
      ConnectionPool.checkout(
        hostname,
        port,
        ssh_config.user,
        Ssh.connect_options(ssh_config)
      )

    with {:ok, conn} <- checkout_result do
      try do
        write_via_sftp(conn, content, remote_path, sftp_opts)
      after
        ConnectionPool.checkin(hostname, port, ssh_config.user)
      end
    end
  end

  @doc """
  Download a file from a remote host to a local path.

  The mirror image of `upload/4`, and it makes the same scp-vs-SFTP choice for
  the same reason: release tarballs are hundreds of MB, and the in-VM SFTP
  channel moves them at ~100-200 KB/s. Used by the `builder.remote` build to
  fetch the tarball back from the build host.

  Creates the local parent directory if it does not exist.
  """
  def download(host, remote_path, local_path, opts \\ []) do
    ssh_config = Keyword.get(opts, :ssh_config, %Ssh{})
    hostname = Host.hostname(host)
    port = Host.port(host, ssh_config)

    with :ok <- ensure_parent_directory(local_path) do
      case scp_key_for_download(ssh_config) do
        :system_ssh ->
          download_via_system_scp(ssh_config, hostname, port, remote_path, local_path)

        {:ok, key_path} ->
          download_via_scp(key_path, ssh_config, hostname, port, remote_path, local_path)

        :none ->
          download_via_sftp_pooled(ssh_config, hostname, port, remote_path, local_path)
      end
    end
  end

  # scp is only usable with an on-disk key *and* the binary present; either
  # missing falls back to SFTP, same as upload/4. system_ssh always uses scp.
  defp scp_key_for_download(%Ssh{system_ssh: true}), do: :system_ssh

  defp scp_key_for_download(ssh_config) do
    case key_file(ssh_config) do
      {:ok, key_path} -> if scp_available?(), do: {:ok, key_path}, else: :none
      :none -> :none
    end
  end

  defp download_via_system_scp(ssh_config, hostname, port, remote_path, local_path) do
    remote = scp_remote(ssh_config, hostname, remote_path)

    with :ok <- system_scp(ssh_config, port, remote, local_path), do: {:ok, local_path}
  end

  defp ensure_parent_directory(local_path) do
    case File.mkdir_p(Path.dirname(local_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:mkdir_failed, reason}}
    end
  end

  defp download_via_scp(key_path, ssh_config, hostname, port, remote_path, local_path) do
    args =
      proxy_flags(ssh_config) ++
        scp_args(key_path, ssh_config.user, hostname, port, local_path, remote_path, :download)

    case System.cmd("scp", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, local_path}
      {output, code} -> {:error, {:scp_failed, code, String.trim(output)}}
    end
  end

  defp download_via_sftp_pooled(ssh_config, hostname, port, remote_path, local_path) do
    checkout_result =
      ConnectionPool.checkout(
        hostname,
        port,
        ssh_config.user,
        Ssh.connect_options(ssh_config)
      )

    with {:ok, conn} <- checkout_result do
      try do
        download_via_sftp(conn, remote_path, local_path)
      after
        ConnectionPool.checkin(hostname, port, ssh_config.user)
      end
    end
  end

  defp download_via_sftp(conn, remote_path, local_path) do
    {:ok, sftp} = :ssh_sftp.start_channel(conn)

    try do
      case :ssh_sftp.read_file(sftp, String.to_charlist(sftp_path(remote_path))) do
        {:ok, content} ->
          File.write!(local_path, content)
          {:ok, local_path}

        {:error, reason} ->
          {:error, {:sftp_read_failed, remote_path, reason}}
      end
    after
      :ssh_sftp.stop_channel(sftp)
    end
  end

  @doc """
  Adapt a remote path for SFTP. SFTP does not expand `~`, but it resolves
  relative paths against the login user's home, so `~/x` becomes `x`.
  """
  def sftp_path("~/" <> rest), do: rest
  def sftp_path(path), do: path

  @doc """
  Resolve the first existing on-disk private key from `ssh.keys`.

  Returns `{:ok, expanded_path}` when a configured key exists on disk, or
  `:none` for `key_data`/agent flows (no usable file). This selection is what
  decides whether `upload/4` uses scp or falls back to the in-VM SFTP channel.
  """
  defdelegate key_file(ssh_config), to: Ssh

  @doc """
  The option flags for a system `ssh` invocation, without a `user@host`
  destination or command.

  Needed because syncing source to a `builder.remote` host pipes local output
  into a remote command (`git archive | ssh host tar -x`), which Erlang's
  `:ssh` cannot express — that one step has to compose a real `ssh` call.

  `BatchMode=yes` fails fast with a clear error instead of hanging on a
  passphrase prompt that, invoked this way, has nowhere to be shown.
  """
  def ssh_flags(ssh_config, port), do: transport_flags(ssh_config, "-p", port)

  @doc """
  Like `ssh_flags/2`, for the system `scp` binary, which takes the port as
  `-P`.
  """
  def scp_flags(ssh_config, port), do: transport_flags(ssh_config, "-P", port)

  defp transport_flags(ssh_config, port_flag, port) do
    flags = [
      port_flag,
      to_string(port),
      "-o",
      "BatchMode=yes",
      "-o",
      "StrictHostKeyChecking=accept-new"
    ]

    # IdentitiesOnly stops ssh offering every ssh-agent key before the -i one;
    # an agent holding several keys trips sshd's MaxAuthTries (default 6)
    # and disconnects with "Too many authentication failures".
    identity =
      case key_file(ssh_config) do
        {:ok, key_path} -> ["-i", key_path, "-o", "IdentitiesOnly=yes"]
        :none -> []
      end

    identity ++ flags ++ proxy_flags(ssh_config)
  end

  @doc """
  Flags that route a system `ssh`/`scp` call through `ssh.proxy` or
  `ssh.proxy_command`.

  A jump host becomes an explicit `ProxyCommand` rather than `-J`: OpenSSH
  runs the `-J` hop as a separate ssh process that doesn't get our `-i` key,
  so the hop fails unless the user's own ssh config happens to cover it.
  """
  def proxy_flags(%Ssh{proxy: proxy} = ssh_config) when is_binary(proxy) do
    {user, host, port} = Proxy.parse_proxy(proxy, user: ssh_config.user)

    identity =
      case key_file(ssh_config) do
        {:ok, key_path} -> "-i #{Xamal.Utils.shell_escape(key_path)} -o IdentitiesOnly=yes "
        :none -> ""
      end

    [
      "-o",
      "ProxyCommand=ssh #{identity}-o BatchMode=yes -o StrictHostKeyChecking=accept-new " <>
        "-p #{port} -W %h:%p #{user}@#{host}"
    ]
  end

  def proxy_flags(%Ssh{proxy_command: command}) when is_binary(command),
    do: ["-o", "ProxyCommand=#{command}"]

  def proxy_flags(_ssh_config), do: []

  @doc """
  Build the argument list passed to the `scp` binary.

  Uses an arg list (not a shell string) to avoid the shell, and carries the
  non-interactive deploy flags `BatchMode=yes` and
  `StrictHostKeyChecking=accept-new`. `IdentitiesOnly=yes` stops scp offering
  every ssh-agent key before the `-i` one; an agent holding several keys trips
  sshd's MaxAuthTries (default 6) and disconnects with "Too many
  authentication failures".
  """
  def scp_args(key_path, user, hostname, port, local_path, remote_path, direction \\ :upload) do
    flags = [
      "-i",
      key_path,
      "-P",
      to_string(port),
      "-o",
      "BatchMode=yes",
      "-o",
      "StrictHostKeyChecking=accept-new",
      "-o",
      "IdentitiesOnly=yes"
    ]

    remote = "#{user}@#{hostname}:#{remote_path}"

    case direction do
      :upload -> flags ++ [local_path, remote]
      :download -> flags ++ [remote, local_path]
    end
  end

  defp upload_via_scp(key_path, ssh_config, hostname, port, local_path, remote_path) do
    args =
      proxy_flags(ssh_config) ++
        scp_args(key_path, ssh_config.user, hostname, port, local_path, remote_path)

    case System.cmd("scp", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, remote_path}
      {output, code} -> {:error, {:scp_failed, code, String.trim(output)}}
    end
  end

  @doc """
  Execute a command list (as built by Commands modules) on a host.
  Joins the command parts into a single shell string.
  """
  def execute_command(host, command_parts, opts \\ []) when is_list(command_parts) do
    command = Enum.map_join(command_parts, " ", &to_string/1)
    execute(host, command, opts)
  end

  @doc """
  Like `execute_command/3`, but raises with a clear message instead of
  returning `{:error, _}`.

  Use this for steps whose failure must stop the task rather than let it
  carry on and report success — most of what a deploy step does (creating a
  release symlink, starting/stopping a service, writing a Caddyfile) is only
  safe to skip past if it actually succeeded.
  """
  def execute_command!(host, command_parts, opts \\ []) when is_list(command_parts) do
    case execute_command(host, command_parts, opts) do
      {:ok, output} ->
        output

      {:error, reason} ->
        Mix.raise(format_error(host, command_parts, reason))
    end
  end

  @doc false
  def format_error(host, command_parts, reason) do
    command = Enum.map_join(command_parts, " ", &to_string/1)

    "SSH command failed on #{host}\n" <>
      "  command: #{command}\n" <>
      "  reason: #{format_reason(reason)}"
  end

  defp format_reason({:exit_status, status, output}) do
    detail = if output in [nil, ""], do: "(no output)", else: indent(output)
    "remote command exited #{status}\n#{detail}"
  end

  defp format_reason({:ssh_connection_failed, host, port, reason}) do
    "could not connect to #{host}:#{port} — #{inspect(reason)}"
  end

  defp format_reason(:timeout), do: "timed out waiting for a response"
  defp format_reason(other), do: inspect(other)

  defp indent(text) do
    text
    |> String.split("\n")
    |> Enum.map(&["    ", &1])
    |> Enum.intersperse("\n")
    |> IO.iodata_to_binary()
  end

  @doc """
  Run a command interactively with a PTY (for IEx remote, bash, etc.).
  Connects local stdin/stdout to the remote session.
  """
  def interactive_exec(host, command, opts \\ []) do
    ssh_config = Keyword.get(opts, :ssh_config, %Ssh{})
    hostname = Host.hostname(host)
    port = Host.port(host, ssh_config)

    with {:ok, conn} <-
           ConnectionPool.checkout(
             hostname,
             port,
             ssh_config.user,
             Ssh.connect_options(ssh_config)
           ) do
      try do
        do_interactive_exec(conn, command)
      after
        ConnectionPool.checkin(hostname, port, ssh_config.user)
      end
    end
  end

  @doc """
  Stream command output to stdout (for logs -f, etc.).
  Runs until the remote command exits or the process is interrupted.
  """
  def streaming_exec(host, command, opts \\ []) do
    ssh_config = Keyword.get(opts, :ssh_config, %Ssh{})

    if ssh_config.system_ssh do
      streaming_exec_via_system_ssh(host, command, ssh_config)
    else
      streaming_exec_via_erlang_ssh(host, command, ssh_config, opts)
    end
  end

  defp streaming_exec_via_system_ssh(host, command, ssh_config) do
    args = system_ssh_args(ssh_config, Host.hostname(host), Host.port(host, ssh_config))

    case System.cmd("ssh", args ++ [command],
           stderr_to_stdout: true,
           into: IO.stream(:stdio, :line)
         ) do
      {_, 0} -> :ok
      {_, code} -> {:error, {:exit_status, code, ""}}
    end
  end

  defp streaming_exec_via_erlang_ssh(host, command, ssh_config, opts) do
    timeout = Keyword.get(opts, :timeout, :infinity)
    hostname = Host.hostname(host)
    port = Host.port(host, ssh_config)

    with {:ok, conn} <-
           ConnectionPool.checkout(
             hostname,
             port,
             ssh_config.user,
             Ssh.connect_options(ssh_config)
           ) do
      try do
        do_streaming_exec(conn, command, timeout)
      after
        ConnectionPool.checkin(hostname, port, ssh_config.user)
      end
    end
  end

  # Private

  defp do_interactive_exec(conn, command) do
    {:ok, channel} = :ssh_connection.session_channel(conn, 30_000)

    # Get terminal dimensions
    {cols, rows} = terminal_size()

    # Request PTY
    pty_opts = [{:term, "xterm-256color"}, {:width, cols}, {:height, rows}]
    pty_result = :ssh_connection.ptty_alloc(conn, channel, pty_opts, 30_000)
    true = pty_result == :success

    # Execute command
    exec_result = :ssh_connection.exec(conn, channel, String.to_charlist(command), 30_000)
    true = exec_result == :success

    case Xamal.TTY.start_link(owner: self()) do
      {:ok, tty} ->
        try do
          interactive_channel_loop(conn, channel, tty)
        after
          Xamal.TTY.close(tty)
        end

      {:error, reason} ->
        :ssh_connection.close(conn, channel)
        {:error, {:tty, reason}}
    end
  end

  defp interactive_channel_loop(conn, channel, tty) do
    receive do
      message ->
        case Xamal.TTY.unwrap_message(tty, message) do
          {:data, data} ->
            :ssh_connection.send(conn, channel, data)
            interactive_channel_loop(conn, channel, tty)

          :eof ->
            :ssh_connection.send_eof(conn, channel)
            interactive_channel_loop(conn, channel, tty)

          :unknown ->
            handle_interactive_channel_message(conn, channel, tty, message)
        end
    end
  end

  defp handle_interactive_channel_message(
         conn,
         channel,
         tty,
         {:ssh_cm, conn, {:data, channel, _type, data}}
       ) do
    IO.write(data)
    interactive_channel_loop(conn, channel, tty)
  end

  defp handle_interactive_channel_message(conn, channel, tty, {:ssh_cm, conn, {:eof, channel}}) do
    interactive_channel_loop(conn, channel, tty)
  end

  defp handle_interactive_channel_message(
         conn,
         channel,
         tty,
         {:ssh_cm, conn, {:exit_status, channel, _status}}
       ) do
    interactive_channel_loop(conn, channel, tty)
  end

  defp handle_interactive_channel_message(
         conn,
         channel,
         _tty,
         {:ssh_cm, conn, {:closed, channel}}
       ) do
    :ok
  end

  defp handle_interactive_channel_message(conn, channel, tty, _message) do
    interactive_channel_loop(conn, channel, tty)
  end

  defp do_streaming_exec(conn, command, timeout) do
    {:ok, channel} = :ssh_connection.session_channel(conn, 30_000)

    exec_result = :ssh_connection.exec(conn, channel, String.to_charlist(command), 30_000)
    true = exec_result == :success

    streaming_loop(conn, channel, timeout)
  end

  defp streaming_loop(conn, channel, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, _type, data}} ->
        IO.write(data)
        streaming_loop(conn, channel, timeout)

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        streaming_loop(conn, channel, timeout)

      {:ssh_cm, ^conn, {:exit_status, ^channel, _status}} ->
        streaming_loop(conn, channel, timeout)

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        :ok
    after
      timeout ->
        :ssh_connection.close(conn, channel)
        {:error, :timeout}
    end
  end

  defp terminal_size do
    cols =
      case :io.columns() do
        {:ok, c} -> c
        _ -> 80
      end

    rows =
      case :io.rows() do
        {:ok, r} -> r
        _ -> 24
      end

    {cols, rows}
  end

  defp exec_command(conn, command, timeout) do
    {:ok, channel} = :ssh_connection.session_channel(conn, timeout)

    # OTP 27+ returns :success instead of :ok
    result = :ssh_connection.exec(conn, channel, String.to_charlist(command), timeout)
    true = result == :success

    receive_output(conn, channel, "", timeout)
  end

  defp receive_output(conn, channel, acc, timeout) do
    receive do
      {:ssh_cm, ^conn, {:data, ^channel, _type, data}} ->
        receive_output(conn, channel, acc <> to_string(data), timeout)

      {:ssh_cm, ^conn, {:eof, ^channel}} ->
        receive_output(conn, channel, acc, timeout)

      {:ssh_cm, ^conn, {:exit_status, ^channel, 0}} ->
        receive_output(conn, channel, acc, timeout)

      {:ssh_cm, ^conn, {:exit_status, ^channel, status}} ->
        :ssh_connection.close(conn, channel)
        {:error, {:exit_status, status, acc}}

      {:ssh_cm, ^conn, {:closed, ^channel}} ->
        {:ok, String.trim(acc)}
    after
      timeout ->
        :ssh_connection.close(conn, channel)
        {:error, :timeout}
    end
  end

  # Release tarballs can take minutes over SFTP, so uploads pass no timeout.
  defp write_via_sftp(conn, content, remote_path, opts) do
    timeout = Keyword.get(opts, :timeout) || :infinity
    path = String.to_charlist(sftp_path(remote_path))

    case :ssh_sftp.start_channel(conn, timeout: timeout) do
      {:ok, sftp} ->
        try do
          with :ok <- set_mode(sftp, path, Keyword.get(opts, :mode), timeout),
               :ok <- :ssh_sftp.write_file(sftp, path, content, timeout) do
            {:ok, remote_path}
          else
            {:error, reason} -> {:error, {:sftp_write_failed, remote_path, reason}}
          end
        rescue
          # OTP 26-27 raise a MatchError on an SFTP timeout instead of
          # returning it.
          e in MatchError -> {:error, {:sftp_write_failed, remote_path, match_reason(e.term)}}
        catch
          # A channel exit reason can hold the call's arguments, which include
          # the content. Drop it.
          :exit, _reason -> {:error, {:sftp_write_failed, remote_path, :channel_exited}}
        after
          :ssh_sftp.stop_channel(sftp)
        end

      {:error, reason} ->
        {:error, {:sftp_write_failed, remote_path, reason}}
    end
  end

  defp match_reason({:error, reason}), do: reason
  defp match_reason(_term), do: :unexpected_reply

  defp set_mode(_sftp, _path, nil, _timeout), do: :ok

  # Set the mode before writing, so the content is never readable with looser
  # permissions. Change an existing file in place; opening it would truncate
  # it, and a failed chmod would then leave it empty.
  defp set_mode(sftp, path, mode, timeout) do
    case :ssh_sftp.write_file_info(sftp, path, file_info(mode: mode), timeout) do
      {:error, :no_such_file} ->
        with {:ok, handle} <- :ssh_sftp.open(sftp, path, [:write], timeout),
             :ok <- :ssh_sftp.close(sftp, handle, timeout) do
          :ssh_sftp.write_file_info(sftp, path, file_info(mode: mode), timeout)
        end

      result ->
        result
    end
  end
end
