defmodule Xamal.Commands.Ports do
  @moduledoc """
  Shared helper for the two service-manager backends
  (`Xamal.Commands.Systemd`, `Xamal.Commands.RcD`): run the same per-port
  command builder across both of a destination's blue-green ports
  (`app_port` and its `alt_port`).
  """

  import Xamal.Commands.Base, only: [chain: 1]

  alias Xamal.Configuration.Caddy

  @doc """
  Run `port_command.(port)` for both `app_port` and `alt_port`, chained with
  `;` so one failing (e.g. the alt_port instance was never started) doesn't
  stop the other from running — mirrors `Xamal.Commands.Base.chain/1`.
  """
  def chain_both(config, port_command) do
    app_port = config.caddy.app_port
    alt_port = Caddy.alt_port(config.caddy)

    chain([port_command.(app_port), port_command.(alt_port)])
  end
end
