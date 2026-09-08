defmodule Xamal.Commands.Builder do
  @moduledoc """
  Build commands: mix release, tarball creation, SCP distribution.
  """

  import Xamal.Commands.Base

  alias Xamal.Configuration
  alias Xamal.Configuration.{Builder, Role}

  @doc """
  Build the release locally with mix release.
  """
  def build_release(config) do
    release_name = config.release.name
    mix_env = config.release.mix_env

    combine([
      ["MIX_ENV=#{mix_env}", "mix", "deps.get", "--only", mix_env],
      ["MIX_ENV=#{mix_env}", "mix", "assets.deploy"],
      ["MIX_ENV=#{mix_env}", "mix", "release", release_name, "--overwrite"]
    ])
  end

  @doc """
  Create a tarball from the built release.
  """
  def create_tarball(config) do
    release_name = config.release.name
    mix_env = config.release.mix_env
    tarball = tarball_path(config)
    release_dir = "_build/#{mix_env}/rel/#{release_name}"

    ["tar", "-czf", tarball, "-C", release_dir, "."]
  end

  @doc """
  Build the release on `builder.remote` (source already synced there —
  see `Xamal.BuildTasks`) and create its tarball, in one combined command.

  Mirrors `build_release/1` plus the `mix local.hex`/`local.rebar`
  `--if-missing` bootstrap steps `build_in_docker/1` uses, since a
  persistent build host — like a fresh container — isn't guaranteed to
  already have them. `tailwind.install`/`esbuild.install` are included
  only when the project actually depends on `:tailwind`/`:esbuild` —
  those Mix tasks don't exist at all otherwise, so calling them
  unconditionally breaks any project that doesn't use one (or either).
  """
  def build_release_remote(config) do
    release_name = config.release.name
    mix_env = config.release.mix_env
    dir = Configuration.build_directory(config)

    combine([
      ["cd", dir],
      ["mix", "local.hex", "--if-missing", "--force"],
      ["mix", "local.rebar", "--if-missing", "--force"],
      ["MIX_ENV=#{mix_env}", "mix", "deps.get", "--only", mix_env],
      asset_install_step(:tailwind, mix_env),
      asset_install_step(:esbuild, mix_env),
      ["MIX_ENV=#{mix_env}", "mix", "assets.deploy"],
      ["MIX_ENV=#{mix_env}", "mix", "release", release_name, "--overwrite"]
    ])
  end

  @doc """
  Create the tarball from a release already built on `builder.remote`.
  """
  def create_tarball_remote(config) do
    release_name = config.release.name
    mix_env = config.release.mix_env
    dir = Configuration.build_directory(config)
    release_dir = "#{dir}/_build/#{mix_env}/rel/#{release_name}"

    ["tar", "-czf", remote_tarball_path(config), "-C", release_dir, "."]
  end

  @doc """
  The tarball path on the `builder.remote` build host.
  """
  def remote_tarball_path(config) do
    "#{Configuration.build_directory(config)}/#{tarball_name(config)}"
  end

  @doc """
  Upload the tarball to a remote host and unpack it.
  """
  def deploy_to_host(config) do
    version = config.version
    release_dir = "#{Configuration.releases_directory(config)}/#{version}"

    combine([
      make_directory(release_dir),
      ["tar", "-xzf", "-", "-C", release_dir]
    ])
  end

  @doc """
  Upload the env file for a role to the remote host.
  """
  def upload_env_file(config, role) do
    env_path = Role.secrets_path(role, config)

    make_directory(Path.dirname(env_path))
  end

  @doc """
  The tarball filename.
  """
  def tarball_name(config) do
    "#{config.release.name}-#{config.version}.tar.gz"
  end

  @doc """
  The local tarball path.
  """
  def tarball_path(config) do
    mix_env = config.release.mix_env
    "_build/#{mix_env}/#{tarball_name(config)}"
  end

  @doc """
  Build the release inside a Docker container for cross-compilation.

  The Docker image can be configured via `builder.docker` in config/xamal.exs:
  - `docker: true` uses a default hexpm/elixir image
  - `docker: "image:tag"` uses the specified image

  Builder args from `builder.args` are passed as environment variables via `-e` flags.
  """
  def build_in_docker(config) do
    image = Builder.docker_image(config.builder)
    release_name = config.release.name
    mix_env = config.release.mix_env

    env_flags =
      (config.builder.args || %{})
      |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    volume_flags =
      (config.builder.volumes || [])
      |> Enum.flat_map(fn vol -> ["-v", vol] end)

    # Use host UID/GID so build artifacts aren't owned by root
    build_steps =
      [
        "command -v git >/dev/null 2>&1 || (apt-get update -qq && apt-get install -y -qq git build-essential >/dev/null 2>&1)",
        "mix local.hex --if-missing --force",
        "mix local.rebar --if-missing --force",
        "MIX_ENV=#{mix_env} mix deps.get --only #{mix_env}",
        "MIX_ENV=#{mix_env} mix deps.compile",
        asset_install_step_string(:tailwind, mix_env),
        asset_install_step_string(:esbuild, mix_env),
        "MIX_ENV=#{mix_env} mix assets.deploy",
        "MIX_ENV=#{mix_env} mix release #{release_name} --overwrite",
        "chown -R $(stat -c '%u:%g' /app) /app/_build /app/deps /app/priv/static"
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" && ")

    combine([
      ["docker", "run", "--rm", "-v", "$(pwd):/app", "-w", "/app"] ++
        volume_flags ++
        env_flags ++
        [image, "sh", "-c", "'#{build_steps}'"]
    ])
  end

  @doc """
  Unpack the tarball on the remote host.
  """
  def unpack_tarball(config) do
    version = config.version
    release_dir = "#{Configuration.releases_directory(config)}/#{version}"
    tarball = "#{release_dir}/#{tarball_name(config)}"

    combine([
      ["tar", "-xzf", tarball, "-C", release_dir],
      remove_file(tarball)
    ])
  end

  # `mix <app>.install` only exists when `app` is an actual dependency of
  # the project being built (it's the Mix task the `:tailwind`/`:esbuild`
  # hex packages themselves define). Calling it unconditionally breaks any
  # project that doesn't depend on one of them — e.g. plain-CSS apps with
  # no `:tailwind` dep — with "The task ... could not be found".
  defp asset_install_step(app, mix_env) do
    if dependency_present?(app) do
      ["MIX_ENV=#{mix_env}", "mix", "#{app}.install", "--if-missing"]
    end
  end

  defp asset_install_step_string(app, mix_env) do
    if dependency_present?(app) do
      "MIX_ENV=#{mix_env} mix #{app}.install --if-missing"
    end
  end

  defp dependency_present?(app) do
    Mix.Project.config()
    |> Keyword.get(:deps, [])
    |> deps_include?(app)
  end

  @doc false
  def deps_include?(deps, app), do: Enum.any?(deps, &(elem(&1, 0) == app))
end
