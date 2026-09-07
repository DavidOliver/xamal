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

  @doas_freebsd_config %{
    @freebsd_config
    | ssh: %Xamal.Configuration.Ssh{become: "doas"}
  }

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

    test "uses ssh.become for privilege escalation on freebsd" do
      assert Caddy.install(@doas_freebsd_config) == ["doas", "pkg", "install", "-y", "caddy"]
    end

    test "uses ssh.become for privilege escalation on linux" do
      config = %{@config | ssh: %Xamal.Configuration.Ssh{become: "doas"}}
      cmd_str = config |> Caddy.install() |> Enum.join(" ")

      assert cmd_str =~ "doas apt-get"
      refute cmd_str =~ "sudo"
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

    test "splices in extra_config alongside reverse_proxy" do
      config = %{
        @config
        | caddy: %{
            @config.caddy
            | extra_config: ~s(@blocked header User-Agent "*BadBot*"\nrespond @blocked 403)
          }
      }

      cmd = Caddy.write_caddyfile(config, 4000)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "@blocked"
      assert cmd_str =~ "respond @blocked 403"
      assert cmd_str =~ "reverse_proxy localhost:4000"
    end
  end

  describe "reload/1" do
    test "reloads from the system Caddyfile so every app on the host stays loaded" do
      assert Caddy.reload(@config) ==
               ["sudo", "caddy", "reload", "--config", "/etc/caddy/Caddyfile"]
    end

    test "uses the FreeBSD system Caddyfile on freebsd" do
      assert Caddy.reload(@freebsd_config) ==
               ["sudo", "caddy", "reload", "--config", "/usr/local/etc/caddy/Caddyfile"]
    end

    test "uses ssh.become for privilege escalation" do
      assert Caddy.reload(@doas_freebsd_config) ==
               ["doas", "caddy", "reload", "--config", "/usr/local/etc/caddy/Caddyfile"]
    end
  end

  describe "start/1" do
    test "starts from the system Caddyfile" do
      assert Caddy.start(@config) == ["caddy", "start", "--config", "/etc/caddy/Caddyfile"]
    end
  end

  describe "install/1 system Caddyfile" do
    test "replaces the package's default site with the import line" do
      cmd_str = Enum.join(Caddy.install(@config), " ")

      assert cmd_str =~ "echo 'import /opt/xamal/*/Caddyfile' | sudo tee /etc/caddy/Caddyfile"
    end
  end

  describe "import_ensure_script/1" do
    setup do
      path = Path.join(System.tmp_dir!(), "xamal_caddyfile_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(path) end)
      %{path: path}
    end

    defp run_script(path) do
      {_, 0} = System.cmd("sh", ["-c", Caddy.import_ensure_script(path)])
      File.read!(path)
    end

    test "creates the file when it doesn't exist", %{path: path} do
      assert run_script(path) == "import /opt/xamal/*/Caddyfile\n"
    end

    test "appends the import after existing content, keeping it", %{path: path} do
      File.write!(path, "{\n  email ops@example.com\n}\n")

      assert run_script(path) ==
               "{\n  email ops@example.com\n}\nimport /opt/xamal/*/Caddyfile\n"
    end

    test "adds a newline first when the last line has none", %{path: path} do
      File.write!(path, "other.example.com {\n  respond ok\n}")

      assert run_script(path) ==
               "other.example.com {\n  respond ok\n}\nimport /opt/xamal/*/Caddyfile\n"
    end

    test "is idempotent", %{path: path} do
      run_script(path)
      assert run_script(path) == "import /opt/xamal/*/Caddyfile\n"
    end
  end

  describe "configure_system_caddyfile/1" do
    test "runs the import script with sudo against the system Caddyfile" do
      [sudo, "sh", "-c", script] = Caddy.configure_system_caddyfile(@config)

      assert sudo == "sudo"
      assert script =~ "grep -qxF"
      assert script =~ "import /opt/xamal/*/Caddyfile"
      assert script =~ ">> /etc/caddy/Caddyfile"
    end

    test "targets /usr/local/etc/caddy/Caddyfile on freebsd" do
      [_sudo, "sh", "-c", script] = Caddy.configure_system_caddyfile(@freebsd_config)

      assert script =~ ">> /usr/local/etc/caddy/Caddyfile"
      refute script =~ " /etc/caddy/Caddyfile"
    end

    test "uses ssh.become for privilege escalation" do
      assert ["doas", "sh", "-c", _] = Caddy.configure_system_caddyfile(@doas_freebsd_config)
    end
  end

  describe "enable/1" do
    test "enables and starts the caddy service" do
      assert Caddy.enable(@config) == ["sudo", "systemctl", "enable", "--now", "caddy"]
    end

    test "enables via sysrc and starts caddy if it isn't running on freebsd" do
      cmd_str = Enum.join(Caddy.enable(@freebsd_config), " ")

      assert cmd_str =~ "sudo sysrc caddy_enable=YES"
      assert cmd_str =~ "service caddy status || sudo service caddy start"
    end

    test "uses ssh.become for privilege escalation" do
      cmd_str = Enum.join(Caddy.enable(@doas_freebsd_config), " ")

      assert cmd_str =~ "doas sysrc caddy_enable=YES"
      refute cmd_str =~ "sudo"
    end
  end

  describe "catch_all_conflicts/1" do
    test "finds :80 catch-all sites in other services' Caddyfiles only" do
      cmd_str = Enum.join(Caddy.catch_all_conflicts(@config), " ")

      assert cmd_str =~ "grep -lx ':80 {' /opt/xamal/*/Caddyfile"
      assert cmd_str =~ "grep -vxF /opt/xamal/my-app/Caddyfile"
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
