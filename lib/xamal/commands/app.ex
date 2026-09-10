defmodule Xamal.Commands.App do
  @moduledoc """
  Release lifecycle commands: start, stop, status, version, exec, logs.
  """

  import Xamal.Commands.Base

  alias Xamal.Configuration
  alias Xamal.Configuration.Role

  @doc """
  Start the release as a daemon on a given port.

  Sources the role env file, sets PORT, then runs `bin/<app> daemon`.
  """
  def start(config, role, port) do
    bin = release_bin(config)
    env_file = Role.secrets_path(role, config)
    service_dir = Configuration.service_directory(config)
    release_name = config.release.name

    combine([
      ["set", "-a"],
      [".", env_file],
      ["set", "+a"],
      ["cd", "#{service_dir}/current"],
      ["PORT=#{port}", "RELEASE_NODE=#{release_name}_#{port}", bin, "daemon"]
    ])
  end

  @doc """
  Start a specific release version on a given port.
  """
  def start_version(config, role, version, port) do
    bin = release_bin(config)
    env_file = Role.secrets_path(role, config)
    release_dir = "#{Configuration.releases_directory(config)}/#{version}"
    release_name = config.release.name

    combine([
      ["set", "-a"],
      [".", env_file],
      ["set", "+a"],
      ["cd", release_dir],
      ["PORT=#{port}", "RELEASE_NODE=#{release_name}_#{port}", bin, "daemon"]
    ])
  end

  @doc """
  Stop the running release.
  """
  def stop(config, port \\ nil) do
    bin = release_bin(config)
    current = Configuration.current_link(config)

    stop_command(config, current, bin, port)
  end

  @doc """
  Stop a specific release version.
  """
  def stop_version(config, version, port \\ nil) do
    bin = release_bin(config)
    release_dir = "#{Configuration.releases_directory(config)}/#{version}"

    stop_command(config, release_dir, bin, port)
  end

  @doc """
  Check if the release is running (pid check).
  """
  def running?(config, port \\ nil) do
    bin = release_bin(config)
    current = Configuration.current_link(config)

    if port do
      release_name = config.release.name
      ["RELEASE_NODE=#{release_name}_#{port}", "#{current}/#{bin}", "pid"]
    else
      ["#{current}/#{bin}", "pid"]
    end
  end

  @doc """
  Get the running release version by reading the current symlink.

  Prints a version only when `current` resolves to an existing directory
  sitting directly under the releases directory. A missing link, a dangling
  one, or one pointing anywhere else exits non-zero, which callers see as
  `{:error, _}` and report as an unknown version.

  Those checks matter because `readlink -f` *canonicalizes* a dangling link
  rather than failing on it. Without them, a `current` left pointing at
  `<releases>/releases` (as an interrupted deploy can leave it) reports the
  version "releases", and `Xamal.BlueGreen`'s failed-boot rollback feeds that
  straight back into `Xamal.Commands.Server.link_current/2` — recreating the
  same broken link on every deploy that fails its health check.
  """
  def current_version(config) do
    current = Configuration.current_link(config)
    releases_dir = Configuration.releases_directory(config)

    combine([
      ["target=$(readlink -f #{current})"],
      ["test", "-d", "\"$target\""],
      ["test", "\"$(dirname \"$target\")\"", "=", releases_dir],
      ["basename", "\"$target\""]
    ])
  end

  @doc """
  Execute a command in the context of the running release.

  Uses `bin/<app> rpc` for non-interactive, `bin/<app> remote` for interactive.
  """
  def exec(config, command, opts \\ []) do
    interactive = Keyword.get(opts, :interactive, false)
    port = Keyword.get(opts, :port)
    bin = release_bin(config)
    current = Configuration.current_link(config)
    env_file = "#{Configuration.env_directory(config)}/app.env"

    # Source the env file so runtime.exs has the required env vars,
    # and set RELEASE_NODE so we connect to the correct node.
    env_prefix =
      ["set -a", ". #{env_file}", "set +a"] ++
        if(port, do: ["export RELEASE_NODE=#{config.release.name}_#{port}"], else: [])

    shell_prefix = Enum.join(env_prefix, " && ")

    if interactive do
      ["#{shell_prefix} &&", "#{current}/#{bin}", "remote"]
    else
      escaped = String.replace(command, "'", "'\\''")
      ["#{shell_prefix} &&", "#{current}/#{bin}", "rpc", "'#{escaped}'"]
    end
  end

  @doc """
  Execute an arbitrary command within the release environment.
  """
  def eval(config, expression) do
    bin = release_bin(config)
    current = Configuration.current_link(config)

    ["#{current}/#{bin}", "eval", Xamal.Utils.shell_escape(expression)]
  end

  @doc """
  Get logs for the release service.

  Uses journalctl (systemd journal) on Linux. On FreeBSD there's no journal;
  each rc.d instance's daemon(8) supervisor appends to its own logfile under
  `<service_dir>/log/`, so this tails that file (or both port instances'
  files when no port is given). `since` has no effect there — see
  `Xamal.Commands.Caddy.logs/2` for the same caveat.
  """
  def logs(config, opts \\ []) do
    if Configuration.freebsd?(config) do
      freebsd_logs(config, opts)
    else
      journalctl_logs(config, opts)
    end
  end

  defp journalctl_logs(config, opts) do
    since = Keyword.get(opts, :since)
    lines = Keyword.get(opts, :lines, 100)
    grep = Keyword.get(opts, :grep)
    follow = Keyword.get(opts, :follow, false)
    port = Keyword.get(opts, :port)

    release_name = config.release.name

    unit =
      if port do
        "#{release_name}@#{port}"
      else
        "#{release_name}@*"
      end

    cmd = ["journalctl", "-u", unit, "--no-pager"]
    cmd = if lines, do: cmd ++ ["-n", "#{lines}"], else: cmd
    cmd = if since, do: cmd ++ ["--since", Xamal.Utils.shell_escape(since)], else: cmd
    cmd = if follow, do: cmd ++ ["-f"], else: cmd

    if grep do
      pipe([cmd, ["grep", Xamal.Utils.shell_escape(grep)]])
    else
      cmd
    end
  end

  defp freebsd_logs(config, opts) do
    lines = Keyword.get(opts, :lines, 100)
    grep = Keyword.get(opts, :grep)
    follow = Keyword.get(opts, :follow, false)
    port = Keyword.get(opts, :port)

    files =
      if port do
        [freebsd_logfile(config, port)]
      else
        ports(config) |> Enum.map(&freebsd_logfile(config, &1))
      end

    cmd = if follow, do: ["tail", "-F" | files], else: ["tail", "-n", "#{lines}" | files]

    if grep do
      pipe([cmd, ["grep", Xamal.Utils.shell_escape(grep)]])
    else
      cmd
    end
  end

  defp freebsd_logfile(config, port) do
    "#{Configuration.service_directory(config)}/log/#{config.release.name}_#{port}.log"
  end

  defp ports(config) do
    app_port = config.caddy.app_port
    [app_port, Configuration.Caddy.alt_port(config.caddy)]
  end

  @doc """
  List all release directories.
  """
  def list_releases(config) do
    ["ls", "-1t", Configuration.releases_directory(config)]
  end

  @doc """
  List stale (non-current) releases.
  """
  def stale_releases(config, keep) do
    pipe([
      list_releases(config),
      ["tail", "-n", "+#{keep + 1}"]
    ])
  end

  @doc """
  Remove a specific release directory.
  """
  def remove_release(config, version) do
    release_dir = "#{Configuration.releases_directory(config)}/#{version}"
    remove_directory(release_dir)
  end

  @doc """
  Show details about the running release.
  """
  def details(config, port \\ nil) do
    bin = release_bin(config)
    current = Configuration.current_link(config)

    node_env =
      if port do
        "RELEASE_NODE=#{config.release.name}_#{port}"
      end

    version_cmd = [node_env, "#{current}/#{bin}", "version"] |> Enum.reject(&is_nil/1)
    pid_cmd = [node_env, "#{current}/#{bin}", "pid"] |> Enum.reject(&is_nil/1)

    chain([
      ["echo", "'Current release:'"],
      ["readlink", "-f", current],
      ["echo", "'Release version:'"],
      version_cmd,
      ["echo", "'PID:'"],
      pid_cmd
    ])
  end

  defp stop_command(config, release_dir, bin, port) do
    if port do
      release_name = config.release.name
      ["RELEASE_NODE=#{release_name}_#{port}", "#{release_dir}/#{bin}", "stop"]
    else
      ["#{release_dir}/#{bin}", "stop"]
    end
  end

  defp release_bin(config) do
    Configuration.Release.bin_path(config.release)
  end
end
