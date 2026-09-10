defmodule Xamal.Commands.AppTest do
  use ExUnit.Case, async: true

  alias Xamal.Commands.App

  @config %Xamal.Configuration{
    raw_config: %{"service" => "my-app"},
    version: "abc1234",
    roles: [%Xamal.Configuration.Role{name: "web", hosts: ["1.2.3.4"]}],
    boot: %Xamal.Configuration.Boot{},
    builder: %Xamal.Configuration.Builder{},
    caddy: %Xamal.Configuration.Caddy{app_port: 4000},
    env: %Xamal.Configuration.Env{clear: %{}, secret_keys: [], secrets: nil},
    ssh: %Xamal.Configuration.Ssh{},
    release: %Xamal.Configuration.Release{name: "my_app", mix_env: "prod"},
    health_check: %Xamal.Configuration.HealthCheck{}
  }

  @role %Xamal.Configuration.Role{name: "web", hosts: ["1.2.3.4"]}

  @freebsd_config %{@config | raw_config: Map.put(@config.raw_config, "os", "freebsd")}

  describe "start/3" do
    test "builds daemon start command" do
      cmd = App.start(@config, @role, 4000)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "bin/my_app"
      assert cmd_str =~ "daemon"
      assert cmd_str =~ "PORT=4000"
    end

    test "sources env file" do
      cmd = App.start(@config, @role, 4000)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "/opt/xamal/my-app/env/roles/web.env"
    end
  end

  describe "stop/1" do
    test "builds stop command" do
      cmd = App.stop(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "bin/my_app"
      assert cmd_str =~ "stop"
      assert cmd_str =~ "current"
    end
  end

  describe "current_version/1" do
    setup do
      dir =
        Path.join(System.tmp_dir!(), "xamal_current_test_#{:erlang.unique_integer([:positive])}")

      File.mkdir_p!(Path.join(dir, "releases"))
      on_exit(fn -> File.rm_rf!(dir) end)
      %{dir: dir}
    end

    test "reads current symlink" do
      cmd = App.current_version(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "readlink"
      assert cmd_str =~ "current"
      assert cmd_str =~ "basename"
    end

    test "prints the version a valid current symlink points at", %{dir: dir} do
      link_current(dir, "releases/abc1234", make: true)

      assert run_current_version(dir) == {:ok, "abc1234"}
    end

    test "fails when current is missing", %{dir: dir} do
      assert {:error, _} = run_current_version(dir)
    end

    test "fails when current is dangling", %{dir: dir} do
      link_current(dir, "releases/releases")

      assert {:error, _} = run_current_version(dir)
    end

    test "fails when current points at the releases directory itself", %{dir: dir} do
      link_current(dir, "releases")

      assert {:error, _} = run_current_version(dir)
    end

    test "fails when current points outside the releases directory", %{dir: dir} do
      File.mkdir_p!(Path.join(dir, "elsewhere/abc1234"))
      link_current(dir, "elsewhere/abc1234")

      assert {:error, _} = run_current_version(dir)
    end

    defp link_current(dir, target, opts \\ []) do
      target_path = Path.join(dir, target)
      if Keyword.get(opts, :make, false), do: File.mkdir_p!(target_path)
      File.ln_s!(target_path, Path.join(dir, "current"))
    end

    # The command hard-codes /opt/xamal/<service>; repoint it at a temp tree
    # so the real shell semantics (readlink -f canonicalizing a dangling
    # link, in particular) can be exercised without touching /opt.
    defp run_current_version(dir) do
      cmd =
        @config
        |> App.current_version()
        |> Enum.join(" ")
        |> String.replace(Xamal.Configuration.service_directory(@config), dir)

      case System.cmd("sh", ["-c", cmd], stderr_to_stdout: true) do
        {output, 0} -> {:ok, String.trim(output)}
        {output, status} -> {:error, {status, String.trim(output)}}
      end
    end
  end

  describe "exec/3" do
    test "non-interactive uses rpc" do
      cmd = App.exec(@config, "MyApp.hello()")
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "rpc"
    end

    test "interactive uses remote" do
      cmd = App.exec(@config, "", interactive: true)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "remote"
    end
  end

  describe "logs/2" do
    test "builds journalctl command with wildcard unit" do
      cmd = App.logs(@config, lines: 50)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "journalctl"
      assert cmd_str =~ "-n 50"
      assert cmd_str =~ "my_app@*"
    end

    test "with specific port" do
      cmd = App.logs(@config, lines: 50, port: 4000)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "journalctl"
      assert cmd_str =~ "-u my_app@4000"
      refute cmd_str =~ "@*"
    end

    test "with grep" do
      cmd = App.logs(@config, grep: "error")
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "journalctl"
      assert cmd_str =~ "grep"
    end

    test "with follow" do
      cmd = App.logs(@config, follow: true)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "-f"
    end

    test "on freebsd, tails both port logfiles when no port given" do
      cmd = App.logs(@freebsd_config, lines: 50)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "tail -n 50"
      assert cmd_str =~ "/opt/xamal/my-app/log/my_app_4000.log"
      assert cmd_str =~ "/opt/xamal/my-app/log/my_app_4001.log"
    end

    test "on freebsd, tails only the given port's logfile" do
      cmd = App.logs(@freebsd_config, lines: 50, port: 4000)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "/opt/xamal/my-app/log/my_app_4000.log"
      refute cmd_str =~ "4001.log"
    end

    test "on freebsd, follows with tail -F" do
      cmd = App.logs(@freebsd_config, follow: true, port: 4000)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "tail -F /opt/xamal/my-app/log/my_app_4000.log"
    end

    test "on freebsd, pipes through grep" do
      cmd = App.logs(@freebsd_config, grep: "error", port: 4000)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "grep"
    end
  end

  describe "list_releases/1" do
    test "lists release directory" do
      cmd = App.list_releases(@config)
      assert cmd == ["ls", "-1t", "/opt/xamal/my-app/releases"]
    end
  end

  describe "stale_releases/2" do
    test "skips N most recent" do
      cmd = App.stale_releases(@config, 3)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "ls -1t"
      assert cmd_str =~ "tail -n +4"
    end
  end

  describe "details/1" do
    test "shows release info" do
      cmd = App.details(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "readlink"
      assert cmd_str =~ "version"
      assert cmd_str =~ "pid"
    end
  end
end
