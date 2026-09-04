defmodule Xamal.Commands.RcDTest do
  use ExUnit.Case, async: true

  alias Xamal.Commands.RcD

  @config %Xamal.Configuration{
    raw_config: %{"service" => "my-app", "os" => "freebsd"},
    roles: [%Xamal.Configuration.Role{name: "web", hosts: ["1.2.3.4"]}],
    boot: %Xamal.Configuration.Boot{},
    builder: %Xamal.Configuration.Builder{},
    caddy: %Xamal.Configuration.Caddy{host: "app.example.com", app_port: 4000, hosts: []},
    env: %Xamal.Configuration.Env{clear: %{}, secret_keys: [], secrets: nil},
    ssh: %Xamal.Configuration.Ssh{user: "deploy"},
    release: %Xamal.Configuration.Release{name: "my_app", mix_env: "prod"},
    health_check: %Xamal.Configuration.HealthCheck{}
  }

  @role %Xamal.Configuration.Role{name: "web", hosts: ["1.2.3.4"]}

  describe "generate_script_content/2" do
    test "generates a fixed-port rc.d script" do
      content = RcD.generate_script_content(@config, 4000)

      assert content =~ "# PROVIDE: my_app_4000"
      assert content =~ ~s(name="my_app_4000")
      assert content =~ ~s(rcvar="my_app_4000_enable")
      assert content =~ ~s(command="/usr/sbin/daemon")
      assert content =~ "-P ${pidfile}"
      assert content =~ "-p ${child_pidfile}"
      assert content =~ "-R 5"
      assert content =~ "-u deploy"
      assert content =~ "/opt/xamal/my-app/current/bin/my_app start"
      assert content =~ "PORT=4000"
      assert content =~ "RELEASE_NODE=my_app_4000"
      assert content =~ "run_rc_command"
    end

    test "uses drain_timeout from config in the custom stop_cmd" do
      config = %{@config | raw_config: Map.put(@config.raw_config, "drain_timeout", 10)}
      content = RcD.generate_script_content(config, 4000)

      assert content =~ "_timeout=10"
    end

    test "sources the shared env file before exporting PORT/RELEASE_NODE" do
      content = RcD.generate_script_content(@config, 4001)

      assert content =~ "/opt/xamal/my-app/env/app.env"
      env_index = :binary.match(content, "app.env") |> elem(0)
      port_index = :binary.match(content, "PORT=4001") |> elem(0)
      assert env_index < port_index
    end
  end

  describe "install_unit/1" do
    test "writes both port scripts and makes them executable" do
      cmd = RcD.install_unit(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "sudo tee /usr/local/etc/rc.d/my_app_4000"
      assert cmd_str =~ "sudo tee /usr/local/etc/rc.d/my_app_4001"
      assert cmd_str =~ "sudo chmod 0555 /usr/local/etc/rc.d/my_app_4000"
      assert cmd_str =~ "sudo chmod 0555 /usr/local/etc/rc.d/my_app_4001"
    end
  end

  describe "start/2" do
    test "starts via service onestart" do
      assert RcD.start(@config, 4000) == ["sudo", "service", "my_app_4000", "onestart"]
    end
  end

  describe "stop/2" do
    test "stops via service onestop" do
      assert RcD.stop(@config, 4001) == ["sudo", "service", "my_app_4001", "onestop"]
    end
  end

  describe "enable/2" do
    test "enables via sysrc" do
      assert RcD.enable(@config, 4000) == ["sudo", "sysrc", "my_app_4000_enable=YES"]
    end
  end

  describe "disable/2" do
    test "disables via sysrc" do
      assert RcD.disable(@config, 4001) == ["sudo", "sysrc", "my_app_4001_enable=NO"]
    end
  end

  describe "stop_all/1" do
    test "stops both port instances with chain" do
      cmd = RcD.stop_all(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "sudo service my_app_4000 onestop"
      assert cmd_str =~ ";"
      assert cmd_str =~ "sudo service my_app_4001 onestop"
    end
  end

  describe "disable_all/1" do
    test "disables both port instances with chain" do
      cmd = RcD.disable_all(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "sudo sysrc my_app_4000_enable=NO"
      assert cmd_str =~ ";"
      assert cmd_str =~ "sudo sysrc my_app_4001_enable=NO"
    end
  end

  describe "remove_unit/1" do
    test "removes both script files" do
      cmd = RcD.remove_unit(@config)

      assert cmd == [
               "sudo",
               "rm",
               "-f",
               "/usr/local/etc/rc.d/my_app_4000",
               "&&",
               "sudo",
               "rm",
               "-f",
               "/usr/local/etc/rc.d/my_app_4001"
             ]
    end
  end

  describe "write_env_symlink/2" do
    test "symlinks role env to app.env" do
      cmd = RcD.write_env_symlink(@config, @role)

      assert cmd == [
               "ln",
               "-sfn",
               "/opt/xamal/my-app/env/roles/web.env",
               "/opt/xamal/my-app/env/app.env"
             ]
    end
  end
end
