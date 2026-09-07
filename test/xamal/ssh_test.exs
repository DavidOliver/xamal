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
