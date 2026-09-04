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
  `Xamal.Commands.App.logs/2` for how that's read back.
  """

  import Xamal.Commands.Base

  alias Xamal.Commands.Ports
  alias Xamal.Configuration
  alias Xamal.Configuration.Caddy

  @rc_dir "/usr/local/etc/rc.d"
  @restart_delay 5

  @doc """
  Generate the rc.d script content for one port instance.
  """
  def generate_script_content(config, port) do
    release_name = config.release.name
    service_dir = Configuration.service_directory(config)
    user = config.ssh.user
    drain_timeout = Configuration.drain_timeout(config)
    name = instance_name(config, port)
    bin = "#{service_dir}/current/bin/#{release_name}"
    # app.sh, not app.env: rc.d sources it with sh, and app.sh single-quotes
    # every value. app.env is in systemd's format, where $ and ` stay live.
    env_file = "#{Configuration.env_directory(config)}/app.sh"

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
    command_args="-P ${pidfile} -p ${child_pidfile} -R #{@restart_delay} -f -o ${logfile} -t ${name} -u #{user} #{bin} start"

    start_precmd="${name}_prestart"
    #{name}_prestart()
    {
        install -d -o #{user} -g #{user} "/var/run/${name}" "#{service_dir}/log"
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
    combine(Enum.map(ports(config), &write_script(config, &1)))
  end

  @doc """
  Start a service instance on the given port.

  Uses `onestart` so it works before the port has ever been `enable`d for
  boot — the same relationship `systemctl start`/`enable` have.
  """
  def start(config, port) do
    ["sudo", "service", instance_name(config, port), "onestart"]
  end

  @doc """
  Stop a service instance on the given port.
  """
  def stop(config, port) do
    ["sudo", "service", instance_name(config, port), "onestop"]
  end

  @doc """
  Enable a service instance for boot-time startup.
  """
  def enable(config, port) do
    ["sudo", "sysrc", "#{instance_name(config, port)}_enable=YES"]
  end

  @doc """
  Disable a service instance from boot-time startup.
  """
  def disable(config, port) do
    ["sudo", "sysrc", "#{instance_name(config, port)}_enable=NO"]
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
    combine(Enum.map(ports(config), &["sudo", "rm", "-f", script_path(config, &1)]))
  end

  @doc """
  Rewrite each port's script only if its content changed.

  Prints `unit-updated` when it replaced either script. rc.d reads the script
  on every `service` call, so there is nothing to reload: the running
  instance keeps running and the next start or stop uses the new script.
  """
  def sync_unit(config) do
    scripts =
      Enum.map_join(ports(config), " ", fn port ->
        path = script_path(config, port)
        staged = "#{path}.xamal-new"

        "echo '#{escaped_script(config, port)}' | sudo tee #{staged} >/dev/null &&" <>
          " if cmp -s #{staged} #{path}; then sudo rm -f #{staged};" <>
          " else sudo chmod 0555 #{staged} && sudo mv #{staged} #{path} && updated=1; fi &&"
      end)

    shell(["updated=0;", scripts, "if [ $updated = 1 ]; then echo unit-updated; fi"])
  end

  @doc """
  Prints other rc.d scripts that run this service's release under a different
  name, and succeeds (exit 0) only if there are any. That's what a
  `release.name` change leaves behind.
  """
  def units_under_other_names(config) do
    own = Enum.flat_map(ports(config), &["-e", script_path(config, &1)])

    pipe([
      ["grep", "-lF", "'#{bin_dir(config)}'", "#{@rc_dir}/*", "2>/dev/null"],
      ["grep", "-vxF" | own]
    ])
  end

  @doc """
  Succeeds (exit 0) when a script for this release name already exists but
  runs a different service directory's release, i.e. another app on the host
  uses the same release name.
  """
  def unit_owned_by_other_service(config) do
    path = script_path(config, config.caddy.app_port)

    combine([
      ["test", "-f", path],
      ["!", "grep", "-qF", "'#{bin_dir(config)}'", path]
    ])
  end

  @doc """
  Prints the rc.d scripts for this app's ports that belong to a different
  release, and succeeds (exit 0) only if there are any.
  """
  def port_conflicts(config) do
    ports = ports(config)
    globs = Enum.map(ports, &"#{@rc_dir}/*_#{&1}")
    own = Enum.flat_map(ports, &["-e", script_path(config, &1)])

    pipe([
      ["ls", "-1d" | globs] ++ ["2>/dev/null"],
      ["grep", "-vxF" | own]
    ])
  end

  @doc """
  How bootstrap names this app's scripts in a conflict message.
  """
  def unit_label(config) do
    names = Enum.map_join(ports(config), ", ", &instance_name(config, &1))
    "rc.d scripts #{names}"
  end

  @doc """
  Release names found by `units_under_other_names/1`, and the shell commands
  that stop and remove them.
  """
  def rename_cleanup(config, found) do
    ports = ports(config)

    old_names =
      found
      |> String.split("\n", trim: true)
      |> Enum.map(fn path ->
        name = Path.basename(path)
        Enum.reduce(ports, name, &String.replace_suffix(&2, "_#{&1}", ""))
      end)
      |> Enum.uniq()

    commands =
      Enum.flat_map(old_names, fn old ->
        Enum.flat_map(ports, fn port ->
          name = "#{old}_#{port}"

          [
            "sudo service #{name} onestop",
            "sudo sysrc -x #{name}_enable",
            "sudo rm #{@rc_dir}/#{name}"
          ]
        end)
      end)

    {old_names, commands}
  end

  defp write_script(config, port) do
    path = script_path(config, port)

    combine([
      pipe([
        ["echo", "'#{escaped_script(config, port)}'"],
        ["sudo", "tee", path]
      ]),
      ["sudo", "chmod", "0555", path]
    ])
  end

  defp escaped_script(config, port) do
    config |> generate_script_content(port) |> String.replace("'", "'\\''")
  end

  defp ports(config), do: [config.caddy.app_port, Caddy.alt_port(config.caddy)]

  defp bin_dir(config), do: "#{Configuration.service_directory(config)}/current/bin/"

  defp script_path(config, port) do
    "#{@rc_dir}/#{instance_name(config, port)}"
  end

  defp instance_name(config, port) do
    "#{config.release.name}_#{port}"
  end
end
