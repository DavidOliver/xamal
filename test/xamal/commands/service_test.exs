defmodule Xamal.Commands.ServiceTest do
  use ExUnit.Case, async: true

  alias Xamal.Commands.{RcD, Service, Systemd}

  @config %Xamal.Configuration{
    raw_config: %{"service" => "my-app"},
    roles: [%Xamal.Configuration.Role{name: "web", hosts: ["1.2.3.4"]}],
    boot: %Xamal.Configuration.Boot{},
    builder: %Xamal.Configuration.Builder{},
    caddy: %Xamal.Configuration.Caddy{host: "app.example.com", app_port: 4000, hosts: []},
    env: %Xamal.Configuration.Env{clear: %{}, secret_keys: [], secrets: nil},
    ssh: %Xamal.Configuration.Ssh{user: "deploy"},
    release: %Xamal.Configuration.Release{name: "my_app", mix_env: "prod"},
    health_check: %Xamal.Configuration.HealthCheck{}
  }

  @freebsd_config %{@config | raw_config: Map.put(@config.raw_config, "os", "freebsd")}
  @role %Xamal.Configuration.Role{name: "web", hosts: ["1.2.3.4"]}

  describe "on linux (default)" do
    test "delegates every function to Systemd" do
      assert Service.install_unit(@config) == Systemd.install_unit(@config)
      assert Service.start(@config, 4000) == Systemd.start(@config, 4000)
      assert Service.stop(@config, 4000) == Systemd.stop(@config, 4000)
      assert Service.enable(@config, 4000) == Systemd.enable(@config, 4000)
      assert Service.disable(@config, 4000) == Systemd.disable(@config, 4000)
      assert Service.stop_all(@config) == Systemd.stop_all(@config)
      assert Service.disable_all(@config) == Systemd.disable_all(@config)
      assert Service.remove_unit(@config) == Systemd.remove_unit(@config)

      assert Service.write_env_symlink(@config, @role) ==
               Systemd.write_env_symlink(@config, @role)
    end
  end

  describe "on freebsd" do
    test "delegates every function to RcD" do
      assert Service.install_unit(@freebsd_config) == RcD.install_unit(@freebsd_config)
      assert Service.start(@freebsd_config, 4000) == RcD.start(@freebsd_config, 4000)
      assert Service.stop(@freebsd_config, 4000) == RcD.stop(@freebsd_config, 4000)
      assert Service.enable(@freebsd_config, 4000) == RcD.enable(@freebsd_config, 4000)
      assert Service.disable(@freebsd_config, 4000) == RcD.disable(@freebsd_config, 4000)
      assert Service.stop_all(@freebsd_config) == RcD.stop_all(@freebsd_config)
      assert Service.disable_all(@freebsd_config) == RcD.disable_all(@freebsd_config)
      assert Service.remove_unit(@freebsd_config) == RcD.remove_unit(@freebsd_config)

      assert Service.write_env_symlink(@freebsd_config, @role) ==
               RcD.write_env_symlink(@freebsd_config, @role)
    end
  end
end
