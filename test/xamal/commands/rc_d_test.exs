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

  @doas_config %{@config | ssh: %Xamal.Configuration.Ssh{user: "deploy", become: "doas"}}

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

    test "prestart pre-creates the logfile owned by ssh.user, not root" do
      # daemon(8) opens the -o logfile while still running as root - if the
      # file doesn't already exist, it's created root-owned/mode 600, which
      # locks out both ssh.user and App.logs/2 (tails as ssh.user, not
      # root). Pre-creating it here (only if missing, so restarts don't
      # truncate existing logs) avoids that. Deliberately ssh.user, not
      # run_as: it's who reads logs back, and daemon(8) opening it as root
      # doesn't care who it's pre-owned by either way.
      content = RcD.generate_script_content(@config, 4000)

      assert content =~
               ~s([ -e "${logfile}" ] || install -o deploy -g deploy -m 640 /dev/null "${logfile}")

      prestart_index = :binary.match(content, "_prestart()") |> elem(0)
      logfile_install_index = :binary.match(content, "install -o deploy") |> elem(0)
      assert prestart_index < logfile_install_index
    end

    test "-u defaults to ssh.user when release.run_as is unset" do
      content = RcD.generate_script_content(@config, 4000)
      assert content =~ "-u deploy"
    end

    test "-u is release.run_as when set, and the pidfile dir is owned by it" do
      config = %{@config | release: %{@config.release | run_as: "app"}}
      content = RcD.generate_script_content(config, 4000)

      assert content =~ "-u app"
      refute content =~ "-u deploy"
      assert content =~ ~s(install -d -o app -g app "/var/run/${name}")
    end

    test "the log directory and logfile stay owned by ssh.user even when run_as differs" do
      # ssh.user is who reads logs back (mix xamal.app.logs); run_as (the
      # release process) never needs direct file access to them - see
      # Commands.App.logs/2 and this module's moduledoc.
      config = %{@config | release: %{@config.release | run_as: "app"}}
      content = RcD.generate_script_content(config, 4000)

      assert content =~
               ~s(install -d -o deploy -g deploy "#{Xamal.Configuration.service_directory(config)}/log")

      assert content =~
               ~s([ -e "${logfile}" ] || install -o deploy -g deploy -m 640 /dev/null "${logfile}")
    end

    test "prestart creates a run_as-owned, per-port scratch dir under shared_directory" do
      # The release itself needs somewhere writable - RELEASE_TMP, Erlang's
      # erl_crash.dump - everything else under service_dir is ssh.user-owned
      # (see this module's moduledoc). Per-port so blue-green's two
      # simultaneously-running instances can't collide.
      config = %{@config | release: %{@config.release | run_as: "app"}}
      content = RcD.generate_script_content(config, 4000)

      assert content =~ ~s(install -d -o app -g app "/opt/xamal/my-app/shared/4000")
    end

    test "exports RELEASE_TMP and ERL_CRASH_DUMP pointing at that scratch dir" do
      content = RcD.generate_script_content(@config, 4001)

      assert content =~ "RELEASE_TMP=/opt/xamal/my-app/shared/4001"
      assert content =~ "ERL_CRASH_DUMP=/opt/xamal/my-app/shared/4001/erl_crash.dump"
      assert content =~ "export PORT RELEASE_NODE RELEASE_TMP ERL_CRASH_DUMP"
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

    test "uses ssh.become for privilege escalation (e.g. doas on FreeBSD)" do
      cmd = RcD.install_unit(@doas_config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "doas tee /usr/local/etc/rc.d/my_app_4000"
      assert cmd_str =~ "doas chmod 0555 /usr/local/etc/rc.d/my_app_4000"
      refute cmd_str =~ "sudo"
    end
  end

  describe "start/2" do
    test "starts via service onestart" do
      assert RcD.start(@config, 4000) == ["sudo", "service", "my_app_4000", "onestart"]
    end

    test "uses ssh.become for privilege escalation" do
      assert RcD.start(@doas_config, 4000) == ["doas", "service", "my_app_4000", "onestart"]
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

    test "uses ssh.become for privilege escalation" do
      cmd = RcD.remove_unit(@doas_config)

      assert cmd == [
               "doas",
               "rm",
               "-f",
               "/usr/local/etc/rc.d/my_app_4000",
               "&&",
               "doas",
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
