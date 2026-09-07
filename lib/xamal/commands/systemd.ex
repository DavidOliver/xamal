defmodule Xamal.Commands.Systemd do
  @moduledoc """
  Systemd service unit management commands.

  Uses template units (`<release>@.service`) with the port as instance identifier,
  enabling blue-green deploys (`myapp@4000` / `myapp@4001`), crash recovery via
  `Restart=on-failure`, and boot-time startup via `systemctl enable`.
  """

  import Xamal.Commands.Base

  alias Xamal.Commands.Ports
  alias Xamal.Configuration
  alias Xamal.Configuration.{Caddy, Role}

  @unit_dir "/etc/systemd/system"

  @doc """
  Generate the systemd unit file content for a template service.
  """
  def generate_unit_content(config) do
    release_name = config.release.name
    service_dir = Configuration.service_directory(config)
    user = config.ssh.user
    drain_timeout = Configuration.drain_timeout(config)

    """
    [Unit]
    Description=#{release_name} (%i)
    After=network.target

    [Service]
    Type=exec
    User=#{user}
    WorkingDirectory=#{service_dir}/current
    EnvironmentFile=-#{service_dir}/env/app.env
    Environment=PORT=%i
    Environment=RELEASE_NODE=#{release_name}_%i
    ExecStart=#{service_dir}/current/bin/#{release_name} start
    Restart=on-failure
    RestartSec=5
    TimeoutStopSec=#{drain_timeout}

    [Install]
    WantedBy=multi-user.target
    """
  end

  @doc """
  Write the template unit file and reload systemd.
  """
  def install_unit(config) do
    content = generate_unit_content(config)
    escaped = String.replace(content, "'", "'\\''")
    path = unit_path(config)
    become = config.ssh.become

    combine([
      pipe([
        ["echo", "'#{escaped}'"],
        [become, "tee", path]
      ]),
      [become, "systemctl", "daemon-reload"]
    ])
  end

  @doc """
  Write the template unit only if its content changed, then reload systemd.

  Prints `unit-updated` when it replaced the file, so the caller can say
  so. `daemon-reload` re-reads unit definitions without restarting running
  services, so the serving instance keeps running and the new definition
  applies from the next `systemctl start`.
  """
  def sync_unit(config) do
    content = generate_unit_content(config)
    escaped = String.replace(content, "'", "'\\''")
    path = unit_path(config)
    staged = "#{path}.xamal-new"
    become = config.ssh.become

    shell([
      "echo '#{escaped}' | #{become} tee #{staged} >/dev/null &&",
      "if cmp -s #{staged} #{path}; then #{become} rm -f #{staged};",
      "else #{become} mv #{staged} #{path} && #{become} systemctl daemon-reload &&",
      "echo unit-updated; fi"
    ])
  end

  @doc """
  Prints other template units that run this service (their `WorkingDirectory`
  is this service's) under a different name, and succeeds (exit 0) only if
  there are any. That's what a `release.name` change leaves behind.
  """
  def units_under_other_names(config) do
    working_dir = "WorkingDirectory=#{Configuration.service_directory(config)}/current"

    pipe([
      ["grep", "-lxF", "'#{working_dir}'", "#{@unit_dir}/*@.service", "2>/dev/null"],
      ["grep", "-vxF", unit_path(config)]
    ])
  end

  @doc """
  Start a service instance on the given port.
  """
  def start(config, port) do
    [config.ssh.become, "systemctl", "start", unit_instance(config, port)]
  end

  @doc """
  Stop a service instance on the given port.
  """
  def stop(config, port) do
    [config.ssh.become, "systemctl", "stop", unit_instance(config, port)]
  end

  @doc """
  Enable a service instance for boot-time startup.
  """
  def enable(config, port) do
    [config.ssh.become, "systemctl", "enable", unit_instance(config, port)]
  end

  @doc """
  Disable a service instance from boot-time startup.
  """
  def disable(config, port) do
    [config.ssh.become, "systemctl", "disable", unit_instance(config, port)]
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
  Remove the unit file and reload systemd.
  """
  def remove_unit(config) do
    become = config.ssh.become

    combine([
      [become, "rm", "-f", unit_path(config)],
      [become, "systemctl", "daemon-reload"]
    ])
  end

  @doc """
  Symlink env/app.env and env/app.sh to the role's env files.
  """
  def write_env_symlink(config, role) do
    env_dir = Configuration.env_directory(config)

    combine([
      ["ln", "-sfn", Role.secrets_path(role, config), "#{env_dir}/app.env"],
      ["ln", "-sfn", Role.shell_env_path(role, config), "#{env_dir}/app.sh"]
    ])
  end

  @doc """
  Succeeds (exit 0) when the template unit for this release name already
  exists but belongs to a different service directory — i.e. another app on
  the host uses the same release name, and installing ours would overwrite it.
  """
  def unit_owned_by_other_service(config) do
    path = unit_path(config)
    working_dir = "WorkingDirectory=#{Configuration.service_directory(config)}/current"

    combine([
      ["test", "-f", path],
      ["!", "grep", "-qxF", "'#{working_dir}'", path]
    ])
  end

  @doc """
  Prints the systemd instances bound to this app's ports that belong to a
  different release, and succeeds (exit 0) only if there are any.
  """
  def port_conflicts(config) do
    ports = [config.caddy.app_port, Caddy.alt_port(config.caddy)]
    patterns = Enum.map(ports, &"'*@#{&1}.service'")
    own = Enum.flat_map(ports, &["-e", "#{unit_instance(config, &1)}.service"])

    pipe([
      ["systemctl", "list-units", "--all", "--plain", "--no-legend" | patterns],
      ["awk", "'{print $1}'"],
      ["grep", "-vxF" | own]
    ])
  end

  @doc """
  How bootstrap names this app's unit in a conflict message.
  """
  def unit_label(config), do: "systemd unit #{config.release.name}@.service"

  @doc """
  Release names found by `units_under_other_names/1`, and the shell commands
  that stop and remove them.
  """
  def rename_cleanup(config, found) do
    old_names =
      found
      |> String.split("\n", trim: true)
      |> Enum.map(&(&1 |> Path.basename() |> String.replace_suffix("@.service", "")))

    ports = [config.caddy.app_port, Caddy.alt_port(config.caddy)]
    become = config.ssh.become

    commands =
      Enum.flat_map(old_names, fn old ->
        instances = Enum.map_join(ports, " ", &"#{old}@#{&1}")

        [
          "#{become} systemctl disable --now #{instances}",
          "#{become} rm #{@unit_dir}/#{old}@.service"
        ]
      end)

    {old_names, commands ++ ["#{become} systemctl daemon-reload"]}
  end

  defp unit_path(config) do
    "#{@unit_dir}/#{config.release.name}@.service"
  end

  defp unit_instance(config, port) do
    "#{config.release.name}@#{port}"
  end
end
