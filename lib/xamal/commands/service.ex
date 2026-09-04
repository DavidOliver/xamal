defmodule Xamal.Commands.Service do
  @moduledoc """
  Dispatches service-manager commands to the OS-appropriate backend.

  `Xamal.Commands.Systemd` on Linux (the default), `Xamal.Commands.RcD` on
  FreeBSD (`os: "freebsd"` in config). Both expose the same functions, so
  callers (`Xamal.AppTasks`, `Xamal.BlueGreen`, `Xamal.ServerTasks`,
  `Xamal.Remove`) don't need to know which OS a destination targets.
  """

  alias Xamal.Commands.{RcD, Systemd}
  alias Xamal.Configuration

  @doc "See `Xamal.Commands.Systemd.install_unit/1` / `Xamal.Commands.RcD.install_unit/1`."
  def install_unit(config), do: backend(config).install_unit(config)

  @doc "See `Xamal.Commands.Systemd.start/2` / `Xamal.Commands.RcD.start/2`."
  def start(config, port), do: backend(config).start(config, port)

  @doc "See `Xamal.Commands.Systemd.stop/2` / `Xamal.Commands.RcD.stop/2`."
  def stop(config, port), do: backend(config).stop(config, port)

  @doc "See `Xamal.Commands.Systemd.enable/2` / `Xamal.Commands.RcD.enable/2`."
  def enable(config, port), do: backend(config).enable(config, port)

  @doc "See `Xamal.Commands.Systemd.disable/2` / `Xamal.Commands.RcD.disable/2`."
  def disable(config, port), do: backend(config).disable(config, port)

  @doc "See `Xamal.Commands.Systemd.stop_all/1` / `Xamal.Commands.RcD.stop_all/1`."
  def stop_all(config), do: backend(config).stop_all(config)

  @doc "See `Xamal.Commands.Systemd.disable_all/1` / `Xamal.Commands.RcD.disable_all/1`."
  def disable_all(config), do: backend(config).disable_all(config)

  @doc "See `Xamal.Commands.Systemd.remove_unit/1` / `Xamal.Commands.RcD.remove_unit/1`."
  def remove_unit(config), do: backend(config).remove_unit(config)

  @doc "See `Xamal.Commands.Systemd.write_env_symlink/2` / `Xamal.Commands.RcD.write_env_symlink/2`."
  def write_env_symlink(config, role), do: backend(config).write_env_symlink(config, role)

  defp backend(config) do
    if Configuration.freebsd?(config), do: RcD, else: Systemd
  end
end
