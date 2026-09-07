defmodule Xamal.SSHTest do
  use ExUnit.Case, async: true

  alias Xamal.Configuration.Ssh

  describe "key_file/1 (scp-vs-sftp selection)" do
    test "returns {:ok, expanded} for an existing on-disk key (scp path)" do
      path = Path.join(System.tmp_dir!(), "xamal_key_#{System.unique_integer([:positive])}")
      File.write!(path, "fake-key")
      on_exit(fn -> File.rm(path) end)

      assert Xamal.SSH.key_file(%Ssh{keys: [path]}) == {:ok, Path.expand(path)}
    end

    test "returns the first existing key when several are configured" do
      missing = "/nonexistent/xamal/key"
      present = Path.join(System.tmp_dir!(), "xamal_key_#{System.unique_integer([:positive])}")
      File.write!(present, "fake-key")
      on_exit(fn -> File.rm(present) end)

      assert Xamal.SSH.key_file(%Ssh{keys: [missing, present]}) == {:ok, Path.expand(present)}
    end

    test "returns :none when no configured key exists on disk (sftp path)" do
      assert Xamal.SSH.key_file(%Ssh{keys: ["/nonexistent/xamal/key"]}) == :none
    end

    test "returns :none when keys is nil (sftp path)" do
      assert Xamal.SSH.key_file(%Ssh{keys: nil}) == :none
    end

    test "returns :none for key_data flows (secrets manager / agent → sftp path)" do
      assert Xamal.SSH.key_file(%Ssh{key_data: "PEM", keys: nil}) == :none
    end
  end

  describe "scp_args/6" do
    test "includes identity, port, and non-interactive options" do
      args =
        Xamal.SSH.scp_args(
          "/keys/id",
          "deploy",
          "10.0.0.1",
          2222,
          "/tmp/app.tar.gz",
          "/srv/app.tar.gz"
        )

      assert ["-i", "/keys/id"] == Enum.take(args, 2)
      assert ["-P", "2222"] == Enum.slice(args, 2, 2)
      assert "BatchMode=yes" in args
      assert "StrictHostKeyChecking=accept-new" in args
      assert "/tmp/app.tar.gz" in args
      assert "deploy@10.0.0.1:/srv/app.tar.gz" in args
    end

    test "passes the port as a string for the default port" do
      args = Xamal.SSH.scp_args("/keys/id", "deploy", "host", 22, "local", "remote")

      assert ["-P", "22"] == Enum.slice(args, 2, 2)
    end

    test "omits -i entirely when key_path is nil (agent-only auth)" do
      args = Xamal.SSH.scp_args(nil, "deploy", "10.0.0.1", 22, "local", "remote")

      refute "-i" in args
      assert ["-P", "22"] == Enum.take(args, 2)
    end
  end

  describe "system_ssh_args/3" do
    test "includes port and non-interactive/agent-friendly options" do
      args = Xamal.SSH.system_ssh_args(%Ssh{user: "deploy"}, "10.0.0.1", 2222)

      assert "-p" in args
      assert "2222" in args
      assert "BatchMode=yes" in args
      assert "StrictHostKeyChecking=accept-new" in args
      assert "deploy@10.0.0.1" in args
    end

    test "adds -i for each configured key, expanding a leading ~" do
      args =
        Xamal.SSH.system_ssh_args(%Ssh{user: "deploy", keys: ["~/.ssh/a", "/keys/b"]}, "h", 22)

      assert Enum.count(args, &(&1 == "-i")) == 2
      assert Path.expand("~/.ssh/a") in args
      assert "/keys/b" in args
    end

    test "omits -i when no keys are configured (agent-only)" do
      args = Xamal.SSH.system_ssh_args(%Ssh{user: "deploy"}, "h", 22)

      refute "-i" in args
    end

    test "adds IdentitiesOnly=yes only when keys_only is true" do
      refute "IdentitiesOnly=yes" in Xamal.SSH.system_ssh_args(%Ssh{user: "d"}, "h", 22)

      args = Xamal.SSH.system_ssh_args(%Ssh{user: "d", keys_only: true}, "h", 22)
      assert "IdentitiesOnly=yes" in args
    end

    test "adds -J for a proxy jump host" do
      args = Xamal.SSH.system_ssh_args(%Ssh{user: "d", proxy: "bastion.example.com"}, "h", 22)

      assert ["-J", "bastion.example.com"] |> Enum.all?(&(&1 in args))
    end

    test "adds a ProxyCommand option when proxy_command is set" do
      args = Xamal.SSH.system_ssh_args(%Ssh{user: "d", proxy_command: "nc %h %p"}, "h", 22)

      assert "ProxyCommand=nc %h %p" in args
    end

    test "adds -F /dev/null when config: false" do
      args = Xamal.SSH.system_ssh_args(%Ssh{user: "d", config: false}, "h", 22)

      assert ["-F", "/dev/null"] |> Enum.all?(&(&1 in args))
    end

    test "does not add -F when config is not explicitly false" do
      refute "-F" in Xamal.SSH.system_ssh_args(%Ssh{user: "d"}, "h", 22)
    end

    test "converts connect_timeout from milliseconds to whole seconds" do
      args = Xamal.SSH.system_ssh_args(%Ssh{user: "d", connect_timeout: 15_000}, "h", 22)

      assert "ConnectTimeout=15" in args
    end

    test "rounds a sub-second connect_timeout up to 1 second" do
      args = Xamal.SSH.system_ssh_args(%Ssh{user: "d", connect_timeout: 500}, "h", 22)

      assert "ConnectTimeout=1" in args
    end
  end

  describe "ssh_flags/2 and scp_flags/2" do
    test "ssh_flags uses -p (lowercase) for the port" do
      args = Xamal.SSH.ssh_flags(%Ssh{user: "d"}, 2222)

      assert ["-p", "2222"] == Enum.take(args, 2)
    end

    test "scp_flags uses -P (uppercase) for the port" do
      args = Xamal.SSH.scp_flags(%Ssh{user: "d"}, 2222)

      assert ["-P", "2222"] == Enum.take(args, 2)
    end

    test "system_ssh_args/3 is ssh_flags/2 plus the user@host destination" do
      ssh_config = %Ssh{user: "deploy", keys: ["/keys/a"], proxy: "bastion"}

      assert Xamal.SSH.system_ssh_args(ssh_config, "10.0.0.1", 22) ==
               Xamal.SSH.ssh_flags(ssh_config, 22) ++ ["deploy@10.0.0.1"]
    end

    test "scp_flags shares the same -o/-i/-J options as ssh_flags, only the port flag differs" do
      ssh_config = %Ssh{user: "d", keys: ["/keys/a"], proxy: "bastion", keys_only: true}

      ssh_rest = ssh_config |> Xamal.SSH.ssh_flags(22) |> Enum.drop(2)
      scp_rest = ssh_config |> Xamal.SSH.scp_flags(22) |> Enum.drop(2)

      assert ssh_rest == scp_rest
    end
  end

  describe "format_error/3" do
    test "includes the host and the joined command" do
      message = Xamal.SSH.format_error("10.0.0.1", ["ls", "-la", "/opt"], :timeout)

      assert message =~ "10.0.0.1"
      assert message =~ "ls -la /opt"
    end

    test "formats a nonzero exit status with its captured output" do
      message = Xamal.SSH.format_error("host", ["false"], {:exit_status, 1, "permission denied"})

      assert message =~ "exited 1"
      assert message =~ "permission denied"
    end

    test "formats a nonzero exit status with no output" do
      message = Xamal.SSH.format_error("host", ["false"], {:exit_status, 127, ""})

      assert message =~ "exited 127"
      assert message =~ "(no output)"
    end

    test "formats a connection failure with host, port, and the underlying reason" do
      reason =
        {:ssh_connection_failed, "10.0.0.1", 22,
         "Unable to connect using the available authentication methods"}

      message = Xamal.SSH.format_error("10.0.0.1", ["true"], reason)

      assert message =~ "could not connect to 10.0.0.1:22"
      assert message =~ "Unable to connect using the available authentication methods"
    end

    test "formats a plain timeout" do
      message = Xamal.SSH.format_error("host", ["true"], :timeout)

      assert message =~ "timed out"
    end

    test "falls back to inspect for an unrecognized reason shape" do
      message = Xamal.SSH.format_error("host", ["true"], {:weird, :reason})

      assert message =~ inspect({:weird, :reason})
    end
  end
end
