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
  alias Xamal.Configuration.Role

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
  Create a symlink from env/app.env to the role-specific env file.
  """
  def write_env_symlink(config, role) do
    role_env = Role.secrets_path(role, config)
    app_env = "#{Configuration.env_directory(config)}/app.env"

    ["ln", "-sfn", role_env, app_env]
  end

  defp unit_path(config) do
    "#{@unit_dir}/#{config.release.name}@.service"
  end

  defp unit_instance(config, port) do
    "#{config.release.name}@#{port}"
  end
end
