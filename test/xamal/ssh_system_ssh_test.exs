defmodule Xamal.SSHSystemSshTest do
  # Not async: puts fake ssh/scp binaries first on PATH.
  use ExUnit.Case, async: false

  alias Xamal.Configuration.Ssh
  alias Xamal.SSH

  describe "system_ssh_args/3" do
    test "includes port, non-interactive options, and the destination last" do
      args = SSH.system_ssh_args(%Ssh{user: "deploy", system_ssh: true}, "10.0.0.1", 2222)

      assert ["-p", "2222"] == Enum.slice(args, 0, 2)
      assert "BatchMode=yes" in args
      assert "StrictHostKeyChecking=accept-new" in args
      assert "deploy@10.0.0.1" == args |> Enum.reverse() |> hd()
    end

    test "omits -i when no key file is configured, so ssh-agent is used" do
      refute "-i" in SSH.system_ssh_args(%Ssh{user: "d", system_ssh: true}, "h", 22)
    end

    test "routes through ssh.proxy_command" do
      args = SSH.system_ssh_args(%Ssh{user: "d", proxy_command: "nc %h %p"}, "h", 22)

      assert "ProxyCommand=nc %h %p" in args
    end

    test "adds -F /dev/null only when config: false" do
      assert ["-F", "/dev/null"]
             |> Enum.all?(&(&1 in SSH.system_ssh_args(%Ssh{config: false}, "h", 22)))

      refute "-F" in SSH.system_ssh_args(%Ssh{}, "h", 22)
    end

    test "converts connect_timeout to whole seconds, at least 1" do
      assert "ConnectTimeout=15" in SSH.system_ssh_args(%Ssh{connect_timeout: 15_000}, "h", 22)
      assert "ConnectTimeout=1" in SSH.system_ssh_args(%Ssh{connect_timeout: 500}, "h", 22)
    end
  end

  describe "system_scp_args/4" do
    test "uses -P for the port and ends with source and destination" do
      args = SSH.system_scp_args(%Ssh{user: "d"}, 2222, "local", "d@h:remote")

      assert ["-P", "2222"] == Enum.slice(args, 0, 2)
      assert Enum.take(args, -2) == ["local", "d@h:remote"]
    end
  end

  describe "with fake ssh/scp binaries" do
    setup do
      root = Path.join(System.tmp_dir!(), "xamal_sysssh_#{System.unique_integer([:positive])}")
      bin = Path.join(root, "bin")
      remote = Path.join(root, "remote")
      log = Path.join(root, "calls.log")
      File.mkdir_p!(bin)
      File.mkdir_p!(remote)

      # ssh: log the args, run the last one (the command) locally.
      File.write!(Path.join(bin, "ssh"), """
      #!/bin/sh
      printf 'ssh %s\\n' "$*" >> #{log}
      for last; do :; done
      exec sh -c "$last"
      """)

      # scp: log the args, copy the last two after stripping user@host:.
      File.write!(Path.join(bin, "scp"), """
      #!/bin/sh
      printf 'scp %s\\n' "$*" >> #{log}
      for a; do src="$dst"; dst="$a"; done
      cp "${src#*:}" "${dst#*:}"
      """)

      File.chmod!(Path.join(bin, "ssh"), 0o755)
      File.chmod!(Path.join(bin, "scp"), 0o755)

      path = System.get_env("PATH")
      System.put_env("PATH", bin <> ":" <> path)

      on_exit(fn ->
        System.put_env("PATH", path)
        File.rm_rf(root)
      end)

      %{remote: remote, log: log, ssh: %Ssh{user: "deploy", system_ssh: true}}
    end

    test "execute runs the command and returns trimmed output", %{ssh: ssh} do
      assert {:ok, "hi"} = SSH.execute("h", "echo hi", ssh_config: ssh)
      assert {:error, {:exit_status, 3, _}} = SSH.execute("h", "exit 3", ssh_config: ssh)
    end

    test "write_file creates the file 0600 before the content arrives, off the command line",
         %{remote: remote, log: log, ssh: ssh} do
      path = Path.join(remote, "app.env")
      secret = "SECRET_KEY_BASE=\"s3cr3t'$x\"\n"

      assert {:ok, ^path} = SSH.write_file("h", secret, path, ssh_config: ssh, mode: 0o600)

      assert File.read!(path) == secret
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
      refute File.read!(log) =~ "s3cr3t"
    end

    test "write_file tightens an existing world-readable file", %{remote: remote, ssh: ssh} do
      path = Path.join(remote, "app.env")
      File.write!(path, "old")
      File.chmod!(path, 0o644)

      assert {:ok, _} = SSH.write_file("h", "new", path, ssh_config: ssh, mode: 0o600)

      assert File.read!(path) == "new"
      assert File.stat!(path).mode |> Bitwise.band(0o777) == 0o600
    end

    test "upload and download go through scp", %{remote: remote, ssh: ssh} do
      local = Path.join(remote, "local.tar.gz")
      uploaded = Path.join(remote, "uploaded.tar.gz")
      downloaded = Path.join([remote, "dl", "back.tar.gz"])
      File.write!(local, "tarball")

      assert {:ok, ^uploaded} = SSH.upload("h", local, uploaded, ssh_config: ssh)
      assert {:ok, ^downloaded} = SSH.download("h", uploaded, downloaded, ssh_config: ssh)
      assert File.read!(downloaded) == "tarball"
    end
  end
end
