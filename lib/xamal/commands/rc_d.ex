defmodule Xamal.Commands.RcD do
  @moduledoc """
  FreeBSD rc.d + daemon(8) service management commands.

  This is the FreeBSD counterpart to `Xamal.Commands.Systemd`, selected when
  `os: "freebsd"` is configured. It closes two gaps versus systemd:

  1. **No template units.** rc.d has no `%i`-style instance parameterization
     (systemd's `<release>@.service` + `<release>@<port>`), so instead of one
     template file, `install_unit/1` generates and installs two fixed,
     per-port scripts up front (`<release>_<app_port>`, `<release>_<alt_port>`)
     — one for each port blue-green ever uses.

  2. **No native restart-on-failure.** rc.d itself doesn't supervise
     processes, so each script runs the release under `daemon(8)` as
     `/usr/sbin/daemon -R 5 ...` (crash → restart after 5s, matching
     systemd's `RestartSec=5`). Per daemon(8): `-P` records the *supervisor's*
     PID (not the child's) — this is what must go in rc.subr's `pidfile` var,
     because signaling the child's PID would just cause `-R` to restart it
     out from under `service stop`. daemon(8) forwards SIGTERM it receives to
     the child before exiting.

  A third, related gap: rc.subr's default `stop_cmd` sends `sig_stop` (TERM)
  and waits on the pid indefinitely via `wait_for_pids` — no timeout, no
  SIGKILL escalation (unlike systemd's `TimeoutStopSec`). Each script defines
  a custom `stop_cmd` that waits up to `drain_timeout` seconds after TERM,
  then SIGKILLs the supervisor and (via a second `-p` child pidfile) the
  release process directly, so a wedged release can't hang a blue-green swap
  forever.

  Output that would go to the systemd journal instead goes to
  `<service_dir>/log/<name>.log` via daemon(8)'s `-o`; see
  `Xamal.Commands.App.logs/2` for how that's read back. `daemon(8)` opens
  that file while still running as root (it only drops to `-u <run_as>`
  for the *child* it forks+execs, not itself), so if the file doesn't
  already exist it gets created root-owned, mode 600 — unreadable by
  `ssh.user` (and so by `App.logs/2`, which tails it as `ssh.user`, not
  root). `${name}_prestart()` pre-creates it owned by `ssh.user` first to
  avoid that; deliberately `ssh.user`, not `run_as` — whoever reads logs
  back is `ssh.user`, and daemon(8) opening it as root doesn't care who
  it's pre-owned by either way.

  `run_as` (`Xamal.Configuration.Release.run_as`, defaults to `ssh.user`)
  is the `-u` target and owns `/var/run/<name>` (the pidfile directory),
  kept in lockstep since that's what daemon(8) actually needs write access
  to under its dropped-privilege identity.
  """

  import Xamal.Commands.Base

  alias Xamal.Commands.Ports
  alias Xamal.Configuration
  alias Xamal.Configuration.{Caddy, Role}

  @rc_dir "/usr/local/etc/rc.d"
  @restart_delay 5

  @doc """
  Generate the rc.d script content for one port instance.
  """
  def generate_script_content(config, port) do
    release_name = config.release.name
    service_dir = Configuration.service_directory(config)
    deploy_user = config.ssh.user
    run_user = Configuration.run_as_user(config)
    drain_timeout = Configuration.drain_timeout(config)
    name = instance_name(config, port)
    bin = "#{service_dir}/current/bin/#{release_name}"
    env_file = "#{Configuration.env_directory(config)}/app.env"

    """
    #!/bin/sh
    #
    # PROVIDE: #{name}
    # REQUIRE: NETWORKING
    # KEYWORD: shutdown

    . /etc/rc.subr

    name="#{name}"
    rcvar="#{name}_enable"

    load_rc_config "$name"
    : ${#{name}_enable:="NO"}

    pidfile="/var/run/${name}/${name}.pid"
    child_pidfile="/var/run/${name}/${name}.child.pid"
    logfile="#{service_dir}/log/${name}.log"

    command="/usr/sbin/daemon"
    command_args="-P ${pidfile} -p ${child_pidfile} -R #{@restart_delay} -f -o ${logfile} -t ${name} -u #{run_user} #{bin} start"

    start_precmd="${name}_prestart"
    #{name}_prestart()
    {
        install -d -o #{run_user} -g #{run_user} "/var/run/${name}"
        install -d -o #{deploy_user} -g #{deploy_user} "#{service_dir}/log"
        [ -e "${logfile}" ] || install -o #{deploy_user} -g #{deploy_user} -m 640 /dev/null "${logfile}"
    }

    stop_cmd="${name}_stop"
    #{name}_stop()
    {
        local _pid _timeout

        _pid=$(check_pidfile "${pidfile}" "${command}")
        [ -z "${_pid}" ] && return 0

        kill -TERM "${_pid}" 2>/dev/null
        _timeout=#{drain_timeout}
        while [ ${_timeout} -gt 0 ] && kill -0 "${_pid}" 2>/dev/null; do
            sleep 1
            _timeout=$((_timeout - 1))
        done

        if kill -0 "${_pid}" 2>/dev/null; then
            kill -KILL "${_pid}" 2>/dev/null
            [ -r "${child_pidfile}" ] && kill -KILL "$(cat "${child_pidfile}")" 2>/dev/null
        fi
    }

    if [ -r "#{env_file}" ]; then
        set -a
        . "#{env_file}"
        set +a
    fi

    PORT=#{port}
    RELEASE_NODE=#{release_name}_#{port}
    export PORT RELEASE_NODE

    run_rc_command "$1"
    """
  end

  @doc """
  Write both port-instance scripts and make them executable.
  """
  def install_unit(config) do
    app_port = config.caddy.app_port
    alt_port = Caddy.alt_port(config.caddy)

    combine([
      write_script(config, app_port),
      write_script(config, alt_port)
    ])
  end

  @doc """
  Start a service instance on the given port.

  Uses `onestart` so it works before the port has ever been `enable`d for
  boot — the same relationship `systemctl start`/`enable` have.
  """
  def start(config, port) do
    [config.ssh.become, "service", instance_name(config, port), "onestart"]
  end

  @doc """
  Stop a service instance on the given port.
  """
  def stop(config, port) do
    [config.ssh.become, "service", instance_name(config, port), "onestop"]
  end

  @doc """
  Enable a service instance for boot-time startup.
  """
  def enable(config, port) do
    [config.ssh.become, "sysrc", "#{instance_name(config, port)}_enable=YES"]
  end

  @doc """
  Disable a service instance from boot-time startup.
  """
  def disable(config, port) do
    [config.ssh.become, "sysrc", "#{instance_name(config, port)}_enable=NO"]
  end

  @doc """
  Stop both port instances (tolerates failures via chain).
  """
  def stop_all(config), do: Ports.chain_both(config, &stop(config, &1))

  @doc """
  Disable both port instances from boot-time startup.
  """
  def disable_all(config), do: Ports.chain_both(config, &disable(config, &1))

  @doc """
  Remove both port-instance scripts.
  """
  def remove_unit(config) do
    app_port = config.caddy.app_port
    alt_port = Caddy.alt_port(config.caddy)
    become = config.ssh.become

    combine([
      [become, "rm", "-f", script_path(config, app_port)],
      [become, "rm", "-f", script_path(config, alt_port)]
    ])
  end

  @doc """
  Create a symlink from env/app.env to the role-specific env file.
  """
  def write_env_symlink(config, role) do
    role_env = Role.secrets_path(role, config)
    app_env = "#{Configuration.env_directory(config)}/app.env"

    ["ln", "-sfn", role_env, app_env]
  end

  defp write_script(config, port) do
    content = generate_script_content(config, port)
    escaped = String.replace(content, "'", "'\\''")
    path = script_path(config, port)
    become = config.ssh.become

    combine([
      pipe([
        ["echo", "'#{escaped}'"],
        [become, "tee", path]
      ]),
      [become, "chmod", "0555", path]
    ])
  end

  defp script_path(config, port) do
    "#{@rc_dir}/#{instance_name(config, port)}"
  end

  defp instance_name(config, port) do
    "#{config.release.name}_#{port}"
  end
end
