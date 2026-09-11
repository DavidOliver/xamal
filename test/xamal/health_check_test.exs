defmodule Xamal.HealthCheckTest do
  use ExUnit.Case, async: true

  alias Xamal.HealthCheck

  @config %Xamal.Configuration{raw_config: %{"service" => "my-app"}}
  @freebsd_config %Xamal.Configuration{raw_config: %{"service" => "my-app", "os" => "freebsd"}}

  describe "check_command/3" do
    test "builds curl command for health check" do
      cmd = HealthCheck.check_command(@config, 4000, "/health")
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "curl"
      assert cmd_str =~ "4000"
      assert cmd_str =~ "/health"
    end

    test "uses default path" do
      cmd = HealthCheck.check_command(@config, 4001)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "/health"
    end

    test "on freebsd uses fetch, which is in the base system, unlike curl" do
      cmd = HealthCheck.check_command(@freebsd_config, 4000, "/health")
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "fetch"
      refute cmd_str =~ "curl"
      assert cmd_str =~ "http://localhost:4000/health"
    end

    test "on freebsd reports 200 only when the request succeeds" do
      # fetch cannot print a status code, and do_poll_remote/5 matches on
      # exactly "200", so the echo has to be gated on fetch's exit status.
      cmd_str = @freebsd_config |> HealthCheck.check_command(4000) |> Enum.join(" ")

      assert cmd_str =~ ~r/fetch .* && echo 200$/
    end
  end

  describe "wait_until_ready/3" do
    test "times out when service is not available" do
      # Use a port that's very unlikely to be listening
      result = HealthCheck.wait_until_ready("127.0.0.1", 19_999, timeout: 1, interval: 1)
      assert result == {:error, :timeout}
    end
  end
end
