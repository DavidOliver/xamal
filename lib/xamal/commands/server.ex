defmodule Xamal.Commands.Server do
  @moduledoc """
  Server management commands: directory creation, bootstrap.
  """

  import Xamal.Commands.Base

  alias Xamal.Configuration

  @doc """
  Create all required directories on the server.
  """
  def bootstrap(config) do
    service_dir = Configuration.service_directory(config)
    user = config.ssh.user
    become = config.ssh.become

    combine([
      [become, "mkdir", "-p", service_dir],
      [become, "chown", "#{user}:#{user}", service_dir],
      make_directory(Configuration.releases_directory(config)),
      make_directory("#{Configuration.env_directory(config)}/roles"),
      make_directory(Configuration.shared_directory(config)),
      make_directory(Configuration.run_directory())
    ])
  end

  @doc """
  Ensure the run directory exists (for locks, audit logs).
  """
  def ensure_run_directory do
    make_directory(Configuration.run_directory())
  end

  @doc """
  Remove the entire service directory.

  Needs `become`: `Configuration.shared_directory/1` (under here) contains
  per-port subdirectories owned by `run_as_user/1`, not `ssh.user` - see
  `Xamal.Commands.RcD`/`Xamal.Commands.Systemd` - which `ssh.user` can't
  necessarily recurse into and delete on its own when the two differ.
  """
  def remove_service_directory(config) do
    [config.ssh.become | remove_directory(Configuration.service_directory(config))]
  end

  @doc """
  List the contents of the releases directory.
  """
  def list_releases(config) do
    ["ls", "-1", Configuration.releases_directory(config)]
  end

  @doc """
  Check the current symlink target.
  """
  def current_version(config) do
    ["readlink", "-f", Configuration.current_link(config)]
  end

  @doc """
  Create/update the current symlink to point to a release version.
  """
  def link_current(config, version) do
    release_path = "#{Configuration.releases_directory(config)}/#{version}"
    current = Configuration.current_link(config)

    ["ln", "-sfn", release_path, current]
  end
end
