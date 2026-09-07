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

  describe "configure_system_caddyfile/1" do
    test "wraps import_ensure_script/1 in sh -c, prefixed with become" do
      cmd = Caddy.configure_system_caddyfile(@config)

      assert [become, "sh", "-c", _quoted] = cmd
      assert become == "sudo"
    end

    test "targets /usr/local/etc/caddy/Caddyfile on freebsd" do
      cmd = Caddy.configure_system_caddyfile(@freebsd_config)
      assert Enum.join(cmd, " ") =~ "/usr/local/etc/caddy/Caddyfile"
    end

    test "uses ssh.become for privilege escalation, wrapping the whole script" do
      cmd = Caddy.configure_system_caddyfile(@doas_freebsd_config)

      assert hd(cmd) == "doas"
      refute Enum.join(cmd, " ") =~ "sudo"
    end
  end

  describe "import_ensure_script/1" do
    test "checks for the import line before appending" do
      script = Caddy.import_ensure_script("/etc/caddy/Caddyfile")

      assert script =~ "grep -qxF 'import /opt/xamal/*/Caddyfile' /etc/caddy/Caddyfile"
      assert script =~ "||"
    end

    test "appends rather than overwrites (only >>, never a bare >)" do
      script = Caddy.import_ensure_script("/etc/caddy/Caddyfile")

      refute script =~ ~r/[^>]> \/etc\/caddy\/Caddyfile/
      assert script =~ ">> /etc/caddy/Caddyfile"
    end

    test "guards against a missing trailing newline before appending" do
      script = Caddy.import_ensure_script("/etc/caddy/Caddyfile")

      assert script =~ "tail -c1"
      assert script =~ "-s /etc/caddy/Caddyfile"
    end

    test "behaves correctly end-to-end against a real file, for every starting state" do
      cases = [
        {"missing file", nil, ["import /opt/xamal/*/Caddyfile"]},
        {"empty file", "", ["import /opt/xamal/*/Caddyfile"]},
        {"trailing newline", "foo {\n  bar\n}\n",
         ["foo {", "  bar", "}", "import /opt/xamal/*/Caddyfile"]},
        {"no trailing newline", "foo {\n  bar\n}",
         ["foo {", "  bar", "}", "import /opt/xamal/*/Caddyfile"]}
      ]

      for {label, initial, expected_lines} <- cases do
        path = Path.join(System.tmp_dir!(), "xamal_caddyfile_test_#{System.unique_integer()}")
        if initial, do: File.write!(path, initial)

        script = Caddy.import_ensure_script(path)
        {output, 0} = System.cmd("sh", ["-c", script], stderr_to_stdout: true)
        assert output == "", "#{label}: expected no output, got #{inspect(output)}"

        content = File.read!(path)
        assert String.split(content, "\n", trim: true) == expected_lines, label
        assert String.ends_with?(content, "\n"), "#{label}: should end with a newline"

        # Idempotent: running it again must not duplicate the import line.
        {_, 0} = System.cmd("sh", ["-c", script], stderr_to_stdout: true)
        assert File.read!(path) == content, "#{label}: second run changed the file"

        File.rm(path)
      end
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
    test "reloads from the system Caddyfile, not the per-service one" do
      cmd = Caddy.reload(@config)

      assert cmd == ["sudo", "caddy", "reload", "--config", "/etc/caddy/Caddyfile"]
    end

    test "uses ssh.become for privilege escalation" do
      config = %{@config | ssh: %Xamal.Configuration.Ssh{become: "doas"}}
      cmd = Caddy.reload(config)

      assert cmd == ["doas", "caddy", "reload", "--config", "/etc/caddy/Caddyfile"]
    end

    test "on freebsd, targets the system Caddyfile and sets CADDY_ADMIN for the unix socket" do
      cmd = Caddy.reload(@freebsd_config)
      cmd_str = Enum.join(cmd, " ")

      assert hd(cmd) == "sudo"
      assert cmd_str =~ "sh -c"
      assert cmd_str =~ "CADDY_ADMIN=unix//var/run/caddy/caddy.sock"
      assert cmd_str =~ "caddy reload --config /usr/local/etc/caddy/Caddyfile"
    end

    test "on freebsd, still uses ssh.become for privilege escalation" do
      cmd = Caddy.reload(@doas_freebsd_config)

      assert hd(cmd) == "doas"
      refute Enum.join(cmd, " ") =~ "sudo"
    end

    test "an explicit caddy.admin overrides the freebsd default" do
      config = %{@freebsd_config | caddy: %{@freebsd_config.caddy | admin: "localhost:2020"}}
      cmd_str = config |> Caddy.reload() |> Enum.join(" ")

      assert cmd_str =~ "CADDY_ADMIN=localhost:2020"
      refute cmd_str =~ "caddy.sock"
    end

    test "an explicit caddy.admin also applies on linux" do
      config = %{@config | caddy: %{@config.caddy | admin: "localhost:2020"}}
      cmd_str = config |> Caddy.reload() |> Enum.join(" ")

      assert cmd_str =~ "sh -c"
      assert cmd_str =~ "CADDY_ADMIN=localhost:2020"
    end
  end

  describe "start/1" do
    test "starts from the system Caddyfile, not the per-service one" do
      cmd = Caddy.start(@config)

      assert cmd == ["caddy", "start", "--config", "/etc/caddy/Caddyfile"]
    end

    test "on freebsd, sets CADDY_ADMIN for the unix socket" do
      cmd = Caddy.start(@freebsd_config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "CADDY_ADMIN=unix//var/run/caddy/caddy.sock"
      assert cmd_str =~ "caddy start --config /usr/local/etc/caddy/Caddyfile"
    end
  end

  describe "stop/1" do
    test "stops caddy" do
      assert Caddy.stop(@config) == ["caddy", "stop"]
    end

    test "on freebsd, sets CADDY_ADMIN for the unix socket" do
      cmd = Caddy.stop(@freebsd_config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "CADDY_ADMIN=unix//var/run/caddy/caddy.sock"
      assert cmd_str =~ "caddy stop"
    end
  end

  describe "admin_env/1" do
    test "empty on linux when caddy.admin is unset" do
      assert Caddy.admin_env(@config) == []
    end

    test "the freebsd package default when caddy.admin is unset" do
      assert Caddy.admin_env(@freebsd_config) == ["CADDY_ADMIN=unix//var/run/caddy/caddy.sock"]
    end

    test "caddy.admin overrides the freebsd default" do
      config = %{@freebsd_config | caddy: %{@freebsd_config.caddy | admin: "localhost:2020"}}
      assert Caddy.admin_env(config) == ["CADDY_ADMIN=localhost:2020"]
    end

    test "caddy.admin also applies on linux, where nothing is set by default" do
      config = %{@config | caddy: %{@config.caddy | admin: "localhost:2020"}}
      assert Caddy.admin_env(config) == ["CADDY_ADMIN=localhost:2020"]
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
