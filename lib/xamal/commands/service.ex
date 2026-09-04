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

  @doc "See `Xamal.Commands.Systemd.write_env_symlink/2`. The same on every OS."
  def write_env_symlink(config, role), do: Systemd.write_env_symlink(config, role)

  @doc "See `Xamal.Commands.Systemd.sync_unit/1` / `Xamal.Commands.RcD.sync_unit/1`."
  def sync_unit(config), do: backend(config).sync_unit(config)

  @doc "See `Xamal.Commands.Systemd.units_under_other_names/1` / `Xamal.Commands.RcD.units_under_other_names/1`."
  def units_under_other_names(config), do: backend(config).units_under_other_names(config)

  @doc "See `Xamal.Commands.Systemd.unit_owned_by_other_service/1` / `Xamal.Commands.RcD.unit_owned_by_other_service/1`."
  def unit_owned_by_other_service(config), do: backend(config).unit_owned_by_other_service(config)

  @doc "See `Xamal.Commands.Systemd.port_conflicts/1` / `Xamal.Commands.RcD.port_conflicts/1`."
  def port_conflicts(config), do: backend(config).port_conflicts(config)

  @doc "See `Xamal.Commands.Systemd.unit_label/1` / `Xamal.Commands.RcD.unit_label/1`."
  def unit_label(config), do: backend(config).unit_label(config)

  @doc "See `Xamal.Commands.Systemd.rename_cleanup/2` / `Xamal.Commands.RcD.rename_cleanup/2`."
  def rename_cleanup(config, found), do: backend(config).rename_cleanup(config, found)

  defp backend(config) do
    if Configuration.freebsd?(config), do: RcD, else: Systemd
  end
end
