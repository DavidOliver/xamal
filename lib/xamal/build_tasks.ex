defmodule Xamal.BuildTasks do
  @moduledoc """
  Release build and distribution task implementations.
  """

  import Xamal.Hooks
  import Xamal.Output

  alias Xamal.Commands.Base
  alias Xamal.Commands.Builder
  alias Xamal.Configuration
  alias Xamal.Configuration.Builder, as: BuildConfig
  alias Xamal.Context
  alias Xamal.SSH

  # deps.get + assets.deploy + mix release can genuinely take minutes;
  # SSH.execute_command!/3 defaults to 30s, far too short here.
  @remote_build_timeout 600_000

  def deliver(_args, opts, context) do
    skip_hooks = Keyword.get(opts, :skip_hooks, false)
    run_hook("pre-build", [skip_hooks: skip_hooks], context)
    build([], opts, context)
    run_hook("post-build", [skip_hooks: skip_hooks], context)
    upload([], opts, context)
  end

  def build(_args, _opts, context) do
    config = context.config

    cond do
      BuildConfig.docker?(config.builder) -> build_via_docker(config)
      BuildConfig.remote?(config.builder) -> build_via_remote(config)
      true -> build_locally(config)
    end
  end

  defp build_locally(config) do
    say("Building release locally...", :magenta)
    cmd_str = Base.to_command_string(Builder.build_release(config))

    case System.cmd("sh", ["-c", cmd_str], stderr_to_stdout: true, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        say("Release built successfully", :green)
        create_tarball_locally!(config)

      {_, code} ->
        raise "Build failed with exit code #{code}"
    end
  end

  defp build_via_docker(config) do
    verify_docker_available!()
    image = BuildConfig.docker_image(config.builder)
    say("Building release in Docker (#{image})...", :magenta)

    cmd_str = Base.to_command_string(Builder.build_in_docker(config))

    case System.cmd("sh", ["-c", cmd_str], stderr_to_stdout: true, into: IO.stream(:stdio, :line)) do
      {_, 0} ->
        say("Release built successfully", :green)
        create_tarball_locally!(config)

      {_, code} ->
        raise """
        Docker build failed with exit code #{code}.

        Image: #{image}

        This usually means:
          - The Docker image does not exist on the registry (check the tag)
          - Docker cannot pull the image (check network/auth)
          - The build commands failed inside the container

        To debug, try:
          docker pull #{image}
        """
    end
  end

  defp create_tarball_locally!(config) do
    say("Creating tarball...", :magenta)
    tarball_str = Base.to_command_string(Builder.create_tarball(config))

    case System.cmd("sh", ["-c", tarball_str], stderr_to_stdout: true) do
      {_, 0} -> say("Tarball created: #{Builder.tarball_path(config)}", :green)
      {output, _} -> raise "Failed to create tarball: #{output}"
    end
  end

  # `builder.remote` build: source is synced to the build host with `git
  # archive | ssh ... tar -x` (always over the real ssh/scp binaries,
  # regardless of ssh.system_ssh — piping local output into a remote
  # command isn't something Erlang's :ssh does), then `mix release` and the
  # tarball run there via the normal SSH.execute_command! path, then the
  # tarball is scp'd back to the same local path a local/docker build would
  # have produced, so mix xamal.build.upload needs no changes at all. This
  # means the common case here — build host and deploy host are the same
  # box — pays for a redundant download-then-reupload round trip, in
  # exchange for every builder mode producing an identical local artifact.
  defp build_via_remote(config) do
    destination = config.builder.remote
    say("Building release on #{destination}...", :magenta)

    say("  Syncing source to #{destination}...", :magenta)
    sync_source_to_remote!(config)

    {ssh_config, host} = remote_build_target(config)

    say("  Running mix release on #{destination}...", :magenta)

    SSH.execute_command!(host, Builder.build_release_remote(config),
      ssh_config: ssh_config,
      timeout: @remote_build_timeout
    )

    say("Release built successfully", :green)
    say("Creating tarball on #{destination}...", :magenta)

    SSH.execute_command!(host, Builder.create_tarball_remote(config),
      ssh_config: ssh_config,
      timeout: 120_000
    )

    say("  Fetching tarball from #{destination}...", :magenta)
    fetch_tarball!(config)

    say("Tarball created: #{Builder.tarball_path(config)}", :green)
  end

  # Split "user@host" (falling back to ssh.user for a bare "host") into the
  # {ssh_config, host} SSH.execute_command!/3 expects — builder.remote may
  # name a different user than the deploy hosts (a dedicated build server),
  # so ssh.user can't just be reused as-is.
  defp remote_build_target(config) do
    case String.split(config.builder.remote, "@", parts: 2) do
      [user, host] -> {%{config.ssh | user: user}, host}
      [host] -> {config.ssh, host}
    end
  end

  defp sync_source_to_remote!(config) do
    destination = config.builder.remote
    dir = Configuration.build_directory(config)
    flags = config.ssh |> SSH.ssh_flags(config.ssh.port) |> Enum.join(" ")
    remote_setup = "mkdir -p #{dir} && tar -x -C #{dir}"
    pipeline = "git archive --format=tar HEAD | ssh #{flags} #{destination} '#{remote_setup}'"

    case System.cmd("sh", ["-c", pipeline], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        raise "Failed to sync source to build host #{destination} (exit #{code}):\n#{output}"
    end
  end

  defp fetch_tarball!(config) do
    unless System.find_executable("scp") do
      raise "builder.remote requires the scp binary locally, to fetch the built tarball back."
    end

    destination = config.builder.remote
    local_tarball = Builder.tarball_path(config)
    File.mkdir_p!(Path.dirname(local_tarball))

    args =
      SSH.scp_flags(config.ssh, config.ssh.port) ++
        ["#{destination}:#{Builder.remote_tarball_path(config)}", local_tarball]

    case System.cmd("scp", args, stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {output, code} ->
        raise "Failed to fetch tarball from #{destination} (exit #{code}):\n#{output}"
    end
  end

  defp verify_docker_available! do
    case System.cmd("docker", ["info"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      {_, _} ->
        raise """
        Docker is not available.

        The builder is configured to use Docker but the 'docker' command is not \
        working. Make sure Docker is installed and running.
        """
    end
  rescue
    e in ErlangError ->
      reraise RuntimeError,
              [
                message: """
                Docker is not installed.

                The builder is configured to use Docker but the 'docker' command was not \
                found. Install Docker to use Docker-based builds, or remove the 'docker' \
                setting from your builder configuration.

                Original error: #{inspect(e)}
                """
              ],
              __STACKTRACE__
  end

  def upload(_args, _opts, context) do
    config = context.config
    hosts = Context.hosts(context)

    tarball_path = Builder.tarball_path(config)

    unless File.exists?(tarball_path) do
      raise "Tarball not found at #{tarball_path}. Run 'mix xamal.build' first."
    end

    Enum.each(hosts, fn host ->
      say("  Uploading to #{host}...", :magenta)

      version = config.version
      remote_dir = "#{Configuration.releases_directory(config)}/#{version}"

      # Create remote directory
      mkdir_cmd = Base.make_directory(remote_dir)
      SSH.execute_command!(host, mkdir_cmd, ssh_config: config.ssh)

      # Upload via SFTP (works with key_data)
      remote_path = "#{remote_dir}/#{Builder.tarball_name(config)}"

      case SSH.upload(host, tarball_path, remote_path, ssh_config: config.ssh) do
        {:ok, _} ->
          # Unpack on remote
          unpack_cmd = Builder.unpack_tarball(config)
          SSH.execute_command!(host, unpack_cmd, ssh_config: config.ssh)
          say("  Deployed to #{host}", :green)

        {:error, reason} ->
          raise "Failed to upload to #{host}: #{inspect(reason)}"
      end
    end)
  end

  def details(_args, _opts, context) do
    config = context.config

    IO.puts("Build configuration:")
    IO.puts("  Release name: #{config.release.name}")
    IO.puts("  Mix env: #{config.release.mix_env}")
    IO.puts("  Version: #{config.version}")
    IO.puts("  Builder: #{builder_type(config.builder)}")
    IO.puts("  Tarball: #{Builder.tarball_path(config)}")
  end

  defp builder_type(builder) do
    cond do
      BuildConfig.docker?(builder) -> "docker"
      BuildConfig.remote?(builder) -> "remote (#{builder.remote})"
      true -> "local"
    end
  end
end
