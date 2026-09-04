defmodule Xamal.Commands.CaddyTest do
  use ExUnit.Case, async: true

  alias Xamal.Commands.Caddy

  @config %Xamal.Configuration{
    raw_config: %{"service" => "my-app"},
    roles: [%Xamal.Configuration.Role{name: "web", hosts: ["1.2.3.4"]}],
    boot: %Xamal.Configuration.Boot{},
    builder: %Xamal.Configuration.Builder{},
    caddy: %Xamal.Configuration.Caddy{host: "app.example.com", app_port: 4000, hosts: []},
    env: %Xamal.Configuration.Env{clear: %{}, secret_keys: [], secrets: nil},
    ssh: %Xamal.Configuration.Ssh{},
    release: %Xamal.Configuration.Release{name: "my_app", mix_env: "prod"},
    health_check: %Xamal.Configuration.HealthCheck{}
  }

  @freebsd_config %{@config | raw_config: Map.put(@config.raw_config, "os", "freebsd")}

  describe "install/1" do
    test "installs via apt on linux" do
      cmd = Caddy.install(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "apt-get"
      assert cmd_str =~ "caddy"
      assert cmd_str =~ "curl"
    end

    test "installs via pkg on freebsd" do
      assert Caddy.install(@freebsd_config) == ["sudo", "pkg", "install", "-y", "caddy"]
    end
  end

  describe "check_installed/0" do
    test "checks caddy version" do
      assert Caddy.check_installed() == ["caddy", "version"]
    end
  end

  describe "status/1" do
    test "checks via systemctl on linux" do
      assert Caddy.status(@config) == ["systemctl", "is-active", "caddy"]
    end

    test "checks via service on freebsd" do
      assert Caddy.status(@freebsd_config) == ["service", "caddy", "status"]
    end
  end

  describe "configure_system_caddyfile/1" do
    test "writes to /etc/caddy/Caddyfile on linux" do
      cmd = Caddy.configure_system_caddyfile(@config)
      assert Enum.join(cmd, " ") =~ "/etc/caddy/Caddyfile"
    end

    test "writes to /usr/local/etc/caddy/Caddyfile on freebsd" do
      cmd = Caddy.configure_system_caddyfile(@freebsd_config)
      assert Enum.join(cmd, " ") =~ "/usr/local/etc/caddy/Caddyfile"
    end
  end

  describe "logs/2" do
    test "uses journalctl on linux" do
      cmd = Caddy.logs(@config, lines: 50)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "journalctl"
      assert cmd_str =~ "-n 50"
    end

    test "tails the caddy logfile on freebsd" do
      cmd = Caddy.logs(@freebsd_config, lines: 50)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "tail -n 50 /var/log/caddy/caddy.log"
    end

    test "follows with tail -F on freebsd" do
      cmd = Caddy.logs(@freebsd_config, follow: true)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "tail -F /var/log/caddy/caddy.log"
    end
  end

  describe "write_caddyfile/2" do
    test "writes caddyfile with upstream port" do
      cmd = Caddy.write_caddyfile(@config, 4000)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "echo"
      assert cmd_str =~ "app.example.com"
      assert cmd_str =~ "Caddyfile"
    end
  end

  describe "reload/1" do
    test "reloads caddy config" do
      cmd = Caddy.reload(@config)

      assert cmd == ["sudo", "caddy", "reload", "--config", "/opt/xamal/my-app/Caddyfile"]
    end
  end

  describe "write_active_port/2" do
    test "writes port to file" do
      cmd = Caddy.write_active_port(@config, 4001)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "echo"
      assert cmd_str =~ "4001"
      assert cmd_str =~ "active_port"
    end
  end
end
