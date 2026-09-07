defmodule Xamal.ConfigurationTest do
  use ExUnit.Case, async: true

  alias Xamal.Configuration
  alias Xamal.Configuration.{Boot, Builder, Caddy, Role}

  @valid_config %{
    "service" => "my-app",
    "servers" => %{
      "web" => ["192.168.0.1", "192.168.0.2"],
      "worker" => %{
        "hosts" => ["192.168.0.3"],
        "cmd" => ~s[bin/my_app eval "MyApp.Worker.start()"]
      }
    },
    "ssh" => %{"user" => "deploy", "port" => 22},
    "env" => %{
      "clear" => %{"PHX_HOST" => "app.example.com"},
      "secret" => ["SECRET_KEY_BASE"]
    },
    "caddy" => %{
      "host" => "app.example.com",
      "app_port" => 4000
    },
    "boot" => %{"limit" => 10, "wait" => 2},
    "retain_releases" => 5,
    "deploy_timeout" => 30,
    "drain_timeout" => 30
  }

  describe "new/2" do
    test "parses service name" do
      config = Configuration.new(@valid_config)
      assert Configuration.service(config) == "my-app"
    end

    test "parses roles" do
      config = Configuration.new(@valid_config)
      assert length(config.roles) == 2
      role_names = Enum.map(config.roles, & &1.name) |> Enum.sort()
      assert role_names == ["web", "worker"]
    end

    test "parses web role hosts" do
      config = Configuration.new(@valid_config)
      web = Configuration.role(config, "web")
      assert web.hosts == ["192.168.0.1", "192.168.0.2"]
    end

    test "parses worker role hosts and cmd" do
      config = Configuration.new(@valid_config)
      worker = Configuration.role(config, "worker")
      assert worker.hosts == ["192.168.0.3"]
      assert worker.cmd == ~s[bin/my_app eval "MyApp.Worker.start()"]
    end

    test "primary role defaults to web" do
      config = Configuration.new(@valid_config)
      assert Configuration.primary_role_name(config) == "web"
      assert Configuration.primary_host(config) == "192.168.0.1"
    end

    test "all_hosts returns unique hosts" do
      config = Configuration.new(@valid_config)
      hosts = Configuration.all_hosts(config) |> Enum.sort()
      assert hosts == ["192.168.0.1", "192.168.0.2", "192.168.0.3"]
    end

    test "parses boot config" do
      config = Configuration.new(@valid_config)
      assert config.boot.limit == 10
      assert config.boot.wait == 2
    end

    test "parses caddy config" do
      config = Configuration.new(@valid_config)
      assert config.caddy.host == "app.example.com"
      assert config.caddy.app_port == 4000
    end

    test "parses ssh config" do
      config = Configuration.new(@valid_config)
      assert config.ssh.user == "deploy"
      assert config.ssh.port == 22
    end

    test "defaults" do
      config = Configuration.new(@valid_config)
      assert Configuration.readiness_delay(config) == 7
      assert Configuration.deploy_timeout(config) == 30
      assert Configuration.drain_timeout(config) == 30
      assert Configuration.retain_releases(config) == 5
      assert Configuration.os(config) == "linux"
      refute Configuration.freebsd?(config)
    end

    test "parses os" do
      config = Configuration.new(Map.put(@valid_config, "os", "freebsd"))
      assert Configuration.os(config) == "freebsd"
      assert Configuration.freebsd?(config)
    end

    test "directory helpers" do
      config = Configuration.new(@valid_config)
      assert Configuration.service_directory(config) == "/opt/xamal/my-app"
      assert Configuration.releases_directory(config) == "/opt/xamal/my-app/releases"
      assert Configuration.current_link(config) == "/opt/xamal/my-app/current"
      assert Configuration.build_directory(config) == "~/.xamal/builds/my-app"
    end
  end

  describe "validation" do
    test "rejects invalid service name" do
      bad_config = Map.put(@valid_config, "service", "my app!")

      assert_raise ArgumentError, ~r/Service name/, fn ->
        Configuration.new(bad_config)
      end
    end

    test "rejects empty servers" do
      bad_config = Map.put(@valid_config, "servers", nil)

      assert_raise ArgumentError, ~r/No servers/, fn ->
        Configuration.new(bad_config)
      end
    end

    test "rejects retain_releases < 1" do
      bad_config = Map.put(@valid_config, "retain_releases", 0)

      assert_raise ArgumentError, ~r/Must retain at least 1/, fn ->
        Configuration.new(bad_config)
      end
    end

    test "rejects unsupported os" do
      bad_config = Map.put(@valid_config, "os", "windows")

      assert_raise ArgumentError, ~r/Unsupported os/, fn ->
        Configuration.new(bad_config)
      end
    end
  end

  describe "simple server list format" do
    test "creates implicit web role from array" do
      simple_config = Map.put(@valid_config, "servers", ["10.0.0.1", "10.0.0.2"])
      config = Configuration.new(simple_config)
      assert length(config.roles) == 1
      web = Configuration.role(config, "web")
      assert web.hosts == ["10.0.0.1", "10.0.0.2"]
    end
  end

  describe "Boot" do
    test "percentage limit" do
      boot = Boot.new(%{"limit" => "25%"})
      assert Boot.resolved_limit(boot, 20) == 5
    end

    test "percentage limit minimum 1" do
      boot = Boot.new(%{"limit" => "1%"})
      assert Boot.resolved_limit(boot, 3) == 1
    end

    test "integer limit" do
      boot = Boot.new(%{"limit" => 5})
      assert Boot.resolved_limit(boot, 100) == 5
    end

    test "nil limit" do
      boot = Boot.new(%{})
      assert Boot.resolved_limit(boot, 100) == nil
    end
  end

  describe "Builder" do
    test "defaults to local" do
      builder = Builder.new(%{})
      assert Builder.local?(builder)
      refute Builder.docker?(builder)
      refute Builder.remote?(builder)
    end

    test "docker mode" do
      builder = Builder.new(%{"docker" => true, "local" => false})
      assert Builder.docker?(builder)
      refute Builder.local?(builder)
    end
  end

  describe "Caddy" do
    test "hostnames from single host" do
      caddy = Caddy.new(%{"host" => "app.example.com"})
      assert Caddy.hostnames(caddy) == ["app.example.com"]
    end

    test "hostnames from multiple hosts" do
      caddy = Caddy.new(%{"host" => "app.example.com", "hosts" => ["www.example.com"]})
      assert Caddy.hostnames(caddy) == ["app.example.com", "www.example.com"]
    end

    test "alt_port" do
      caddy = Caddy.new(%{"app_port" => 4000})
      assert Caddy.alt_port(caddy) == 4001
    end

    test "manage_system_caddyfile? defaults to true" do
      assert Caddy.manage_system_caddyfile?(Caddy.new(%{}))
      assert Caddy.manage_system_caddyfile?(Caddy.new(nil))
      assert Caddy.manage_system_caddyfile?(%Caddy{})
    end

    test "manage_system_caddyfile? honors an explicit false" do
      caddy = Caddy.new(%{"manage_system_caddyfile" => false})
      refute Caddy.manage_system_caddyfile?(caddy)
    end

    test "generate_caddyfile with host" do
      caddy = Caddy.new(%{"host" => "app.example.com"})
      caddyfile = Caddy.generate_caddyfile(caddy, 4000)
      assert caddyfile =~ "app.example.com"
      assert caddyfile =~ "reverse_proxy"
      assert caddyfile =~ "4000"
    end

    test "generate_caddyfile without host" do
      caddy = Caddy.new(%{})
      caddyfile = Caddy.generate_caddyfile(caddy, 4000)
      assert Regex.match?(~r/:80/, caddyfile)
      assert caddyfile =~ "reverse_proxy"
    end

    test "maintenance caddyfile" do
      caddy = Caddy.new(%{"host" => "app.example.com"})
      caddyfile = Caddy.maintenance_caddyfile(caddy)
      assert caddyfile =~ "503"
      assert caddyfile =~ "maintenance"
    end

    test "parses extra_config" do
      caddy =
        Caddy.new(%{
          "host" => "app.example.com",
          "extra_config" => "respond @blocked 403"
        })

      assert caddy.extra_config == "respond @blocked 403"
    end

    test "generate_caddyfile splices extra_config in alongside reverse_proxy" do
      caddy =
        Caddy.new(%{
          "host" => "app.example.com",
          "extra_config" => "@blocked path /admin/*\nrespond @blocked 404"
        })

      caddyfile = Caddy.generate_caddyfile(caddy, 4000)

      assert caddyfile =~ "@blocked path /admin/*"
      assert caddyfile =~ "respond @blocked 404"
      assert caddyfile =~ "reverse_proxy localhost:4000"
    end

    test "generate_caddyfile without extra_config is unchanged" do
      caddy = Caddy.new(%{"host" => "app.example.com"})
      caddyfile = Caddy.generate_caddyfile(caddy, 4000)

      assert caddyfile =~ "reverse_proxy localhost:4000"
      refute caddyfile =~ "respond"
    end
  end

  describe "Role" do
    test "primary_host returns first host" do
      config = Configuration.new(@valid_config)
      web = Configuration.role(config, "web")
      assert Role.primary_host(web) == "192.168.0.1"
    end
  end
end
