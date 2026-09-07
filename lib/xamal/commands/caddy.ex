defmodule Xamal.Commands.Caddy do
  @moduledoc """
  Caddy install, config generation, reload, and management commands.
  """

  import Xamal.Commands.Base

  alias Xamal.Configuration
  alias Xamal.Configuration.Caddy, as: CaddyConfig

  @freebsd_caddyfile "/usr/local/etc/caddy/Caddyfile"
  @freebsd_logfile "/var/log/caddy/caddy.log"
  # The FreeBSD www/caddy port's rc.d script defaults caddy_admin to this
  # unix socket and exports it as CADDY_ADMIN for every caddy subcommand it
  # runs — but only when invoked *through* the rc.d script (`service caddy
  # ...`). Calling the caddy binary directly, as reload/start do, doesn't
  # inherit that, so `caddy reload`/`caddy start` fall back to caddy's own
  # default admin address (localhost:2019) — which nothing is listening on,
  # since the running instance's admin API is actually this socket. Setting
  # the same env var ourselves is what lets a bare `caddy reload` find it.
  @freebsd_admin_socket "unix//var/run/caddy/caddy.sock"
  @import_line "import /opt/xamal/*/Caddyfile"

  @doc """
  Install Caddy: via apt on Debian/Ubuntu, or via pkg on FreeBSD.
  """
  def install(config) do
    if Configuration.freebsd?(config) do
      [config.ssh.become, "pkg", "install", "-y", "caddy"]
    else
      install_via_apt(config)
    end
  end

  defp install_via_apt(config) do
    become = config.ssh.become

    combine([
      [become, "apt-get", "install", "-y", "apt-transport-https", "curl"],
      pipe([
        ["curl", "-1sLf", "'https://dl.cloudsmith.io/public/caddy/stable/gpg.key'"],
        [
          become,
          "gpg",
          "--batch",
          "--yes",
          "--dearmor",
          "-o",
          "/usr/share/keyrings/caddy-stable-archive-keyring.gpg"
        ]
      ]),
      pipe([
        ["curl", "-1sLf", "'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt'"],
        [become, "tee", "/etc/apt/sources.list.d/caddy-stable.list"]
      ]),
      [become, "apt-get", "update"],
      [become, "apt-get", "install", "-y", "caddy"]
    ])
  end

  @doc """
  Check if Caddy is installed.
  """
  def check_installed do
    ["caddy", "version"]
  end

  @doc """
  Write a Caddyfile to the service directory.
  """
  def write_caddyfile(config, upstream_port) do
    caddyfile_content = CaddyConfig.generate_caddyfile(config.caddy, upstream_port)
    escaped = String.replace(caddyfile_content, "'", "'\\''")
    caddyfile_path = caddyfile_path(config)

    write([
      ["echo", "'#{escaped}'"],
      [caddyfile_path]
    ])
  end

  @doc """
  Write a maintenance mode Caddyfile.
  """
  def write_maintenance_caddyfile(config) do
    caddyfile_content = CaddyConfig.maintenance_caddyfile(config.caddy)
    escaped = String.replace(caddyfile_content, "'", "'\\''")
    caddyfile_path = caddyfile_path(config)

    write([
      ["echo", "'#{escaped}'"],
      [caddyfile_path]
    ])
  end

  @doc """
  Ensure the system Caddyfile imports service Caddyfiles, without touching
  anything else in the file — appends the import line only if it isn't
  already present, so any global options block or other sites you manage
  there yourself are left alone. Creates the file if it doesn't exist yet;
  if it exists but its last line has no trailing newline, one is inserted
  first so the import line lands on its own line instead of getting glued
  onto the end of whatever was already there.
  """
  def configure_system_caddyfile(config) do
    path = system_caddyfile_path(config)

    [config.ssh.become | shell([import_ensure_script(path)])]
  end

  @doc """
  The raw shell script `configure_system_caddyfile/1` runs (unescaped, not
  yet wrapped for remote execution) — public so it can be exercised directly.
  """
  def import_ensure_script(path) do
    """
    grep -qxF '#{@import_line}' #{path} 2>/dev/null || {
        if [ -s #{path} ] && [ -n "$(tail -c1 #{path})" ]; then
            printf '\\n' >> #{path}
        fi
        printf '%s\\n' '#{@import_line}' >> #{path}
    }
    """
  end

  @doc """
  Reload Caddy configuration (graceful - drains existing connections).

  Reloads from the *system* Caddyfile, not the per-service one — Caddy's
  `reload --config` replaces the entire live config with whatever that file
  (and its imports) resolves to, so reloading from the per-service file
  alone would drop every other site and any global options block from the
  running config on every deploy.
  """
  def reload(config) do
    cmd = ["caddy", "reload", "--config", system_caddyfile_path(config)]

    case admin_env(config) do
      [] -> [config.ssh.become | cmd]
      env -> [config.ssh.become | shell(env ++ cmd)]
    end
  end

  @doc """
  Start Caddy with the system Caddyfile (see `reload/1` for why not the
  per-service one).
  """
  def start(config) do
    cmd = ["caddy", "start", "--config", system_caddyfile_path(config)]

    case admin_env(config) do
      [] -> cmd
      env -> shell(env ++ cmd)
    end
  end

  @doc """
  Stop Caddy.
  """
  def stop(config) do
    cmd = ["caddy", "stop"]

    case admin_env(config) do
      [] -> cmd
      env -> shell(env ++ cmd)
    end
  end

  @doc """
  The `CADDY_ADMIN=...` env var assignment (as a one-element list, or `[]`
  when nothing needs overriding) `reload/1`/`start/1`/`stop/1` prefix onto a
  direct `caddy` invocation — `caddy.admin` if set, else FreeBSD's
  `www/caddy` package default on FreeBSD, else nothing (Caddy's own default
  already matches on Linux).
  """
  def admin_env(config) do
    case config.caddy.admin do
      nil ->
        if Configuration.freebsd?(config), do: ["CADDY_ADMIN=#{@freebsd_admin_socket}"], else: []

      admin ->
        ["CADDY_ADMIN=#{admin}"]
    end
  end

  @doc """
  Check Caddy status.
  """
  def status(config) do
    if Configuration.freebsd?(config) do
      ["service", "caddy", "status"]
    else
      ["systemctl", "is-active", "caddy"]
    end
  end

  @doc """
  Read the active port from the active_port file.
  """
  def read_active_port(config) do
    ["cat", active_port_path(config)]
  end

  @doc """
  Write the active port to the active_port file.
  """
  def write_active_port(config, port) do
    write([
      ["echo", "#{port}"],
      [active_port_path(config)]
    ])
  end

  @doc """
  Get Caddy proxy logs.

  Uses journalctl on Linux. On FreeBSD, the `www/caddy` package's own rc.d
  script logs to `/var/log/caddy/caddy.log` (no journald equivalent), so this
  tails that file instead; `since` has no effect there since plain log lines
  carry no filterable timestamp prefix.

  Options: lines (default 100), since, grep, follow.
  """
  def logs(config, opts \\ []) do
    if Configuration.freebsd?(config) do
      freebsd_logs(opts)
    else
      journalctl_logs(opts)
    end
  end

  defp journalctl_logs(opts) do
    since = Keyword.get(opts, :since)
    lines = Keyword.get(opts, :lines, 100)
    grep = Keyword.get(opts, :grep)
    follow = Keyword.get(opts, :follow, false)

    cmd = ["journalctl", "-u", "caddy", "--no-pager"]
    cmd = if lines, do: cmd ++ ["-n", "#{lines}"], else: cmd
    cmd = if since, do: cmd ++ ["--since", Xamal.Utils.shell_escape(since)], else: cmd
    cmd = if follow, do: cmd ++ ["-f"], else: cmd

    if grep do
      pipe([cmd, ["grep", Xamal.Utils.shell_escape(grep)]])
    else
      cmd
    end
  end

  defp freebsd_logs(opts) do
    lines = Keyword.get(opts, :lines, 100)
    grep = Keyword.get(opts, :grep)
    follow = Keyword.get(opts, :follow, false)

    cmd =
      if follow do
        ["tail", "-F", @freebsd_logfile]
      else
        ["tail", "-n", "#{lines}", @freebsd_logfile]
      end

    if grep do
      pipe([cmd, ["grep", Xamal.Utils.shell_escape(grep)]])
    else
      cmd
    end
  end

  defp caddyfile_path(config) do
    "#{Configuration.service_directory(config)}/Caddyfile"
  end

  defp active_port_path(config) do
    "#{Configuration.service_directory(config)}/active_port"
  end

  defp system_caddyfile_path(config) do
    if Configuration.freebsd?(config) do
      @freebsd_caddyfile
    else
      "/etc/caddy/Caddyfile"
    end
  end
end
