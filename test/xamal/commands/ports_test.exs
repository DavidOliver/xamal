defmodule Xamal.Commands.PortsTest do
  use ExUnit.Case, async: true

  alias Xamal.Commands.Ports

  @config %Xamal.Configuration{
    caddy: %Xamal.Configuration.Caddy{app_port: 4000}
  }

  describe "chain_both/2" do
    test "runs the builder for app_port and alt_port, chained with ;" do
      cmd = Ports.chain_both(@config, fn port -> ["echo", "#{port}"] end)

      assert cmd == ["echo", "4000", ";", "echo", "4001"]
    end
  end
end
