defmodule Xamal.Configuration.Release do
  @moduledoc """
  Elixir release configuration.

  `run_as` is the OS account the release *process* runs under (the
  systemd `User=`, or the FreeBSD rc.d/daemon(8) `-u` target) — distinct
  from `ssh.user`, which is who deploys/administers the host. Defaults to
  `ssh.user` when unset, matching xamal's original behavior where one
  account did both. Set it to run the release under a separate, less
  privileged account than the one used to deploy: worthwhile since
  `ssh.user` typically has passwordless root (`become`) for provisioning,
  which a network-facing app process has no business inheriting.
  """

  defstruct [:name, :mix_env, :run_as]

  def new(config, raw_config) when is_map(config) do
    service = Map.get(raw_config, "service", "app")

    %__MODULE__{
      name: Map.get(config, "name", Xamal.Utils.to_release_name(service)),
      mix_env: Map.get(config, "mix_env", "prod"),
      run_as: Map.get(config, "run_as")
    }
  end

  def new(_, raw_config), do: new(%{}, raw_config)

  @doc """
  The release binary path within a release directory.
  """
  def bin_path(%__MODULE__{name: name}) do
    "bin/#{name}"
  end
end
