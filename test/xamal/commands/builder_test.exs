defmodule Xamal.Commands.BuilderTest do
  use ExUnit.Case, async: true

  alias Xamal.Commands.Builder

  @config %Xamal.Configuration{
    raw_config: %{"service" => "my-app"},
    version: "abc1234",
    roles: [],
    boot: %Xamal.Configuration.Boot{},
    builder: %Xamal.Configuration.Builder{},
    caddy: %Xamal.Configuration.Caddy{},
    env: %Xamal.Configuration.Env{clear: %{}, secret_keys: [], secrets: nil},
    ssh: %Xamal.Configuration.Ssh{},
    release: %Xamal.Configuration.Release{name: "my_app", mix_env: "prod"},
    health_check: %Xamal.Configuration.HealthCheck{}
  }

  describe "build_release/1" do
    test "builds mix release command" do
      cmd = Builder.build_release(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "MIX_ENV=prod"
      assert cmd_str =~ "mix deps.get"
      assert cmd_str =~ "mix release my_app"
      assert cmd_str =~ "--overwrite"
    end
  end

  describe "create_tarball/1" do
    test "builds tar command" do
      cmd = Builder.create_tarball(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "tar"
      assert cmd_str =~ "-czf"
      assert cmd_str =~ "my_app-abc1234.tar.gz"
      assert cmd_str =~ "_build/prod/rel/my_app"
    end
  end

  describe "deploy_to_host/1" do
    test "creates release directory and unpacks" do
      cmd = Builder.deploy_to_host(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "mkdir -p"
      assert cmd_str =~ "/opt/xamal/my-app/releases/abc1234"
      assert cmd_str =~ "tar -xzf"
    end
  end

  describe "tarball_name/1" do
    test "returns tarball filename" do
      assert Builder.tarball_name(@config) == "my_app-abc1234.tar.gz"
    end
  end

  describe "tarball_path/1" do
    test "returns local tarball path" do
      assert Builder.tarball_path(@config) == "_build/prod/my_app-abc1234.tar.gz"
    end
  end

  describe "build_release_remote/1" do
    test "cds into the build directory and bootstraps hex/rebar/asset tools" do
      cmd = Builder.build_release_remote(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "cd ~/.xamal/builds/my-app"
      assert cmd_str =~ "mix local.hex --if-missing --force"
      assert cmd_str =~ "mix local.rebar --if-missing --force"
      assert cmd_str =~ "MIX_ENV=prod mix deps.get --only prod"
      assert cmd_str =~ "MIX_ENV=prod mix assets.deploy"
      assert cmd_str =~ "MIX_ENV=prod mix release my_app --overwrite"
    end

    test "omits tailwind/esbuild install steps when the project has neither dependency" do
      # `mix <app>.install` is a task defined by the `:tailwind`/`:esbuild`
      # hex packages themselves - it doesn't exist at all for a project
      # that doesn't depend on them (e.g. a plain-CSS app with no JS
      # bundler). Calling it unconditionally breaks that project with
      # "The task ... could not be found". Xamal's own project (which
      # these tests run under) has neither dependency, so this exercises
      # that exact scenario for real - see deps_include?/2 below for the
      # presence-branch logic.
      cmd_str = @config |> Builder.build_release_remote() |> Enum.join(" ")

      refute cmd_str =~ "tailwind.install"
      refute cmd_str =~ "esbuild.install"
    end

    test "deps_include?/2 detects the presence of an asset tool dependency" do
      # This is the gate `build_release_remote/1` and `build_in_docker/1`
      # use to decide whether to include the tailwind/esbuild install
      # steps (each still MIX_ENV=prod-prefixed like every other step,
      # per the test above - deps.get, assets.deploy, release).
      assert Builder.deps_include?([{:tailwind, "~> 0.2"}], :tailwind)
      assert Builder.deps_include?([{:esbuild, "~> 0.8"}], :esbuild)
      refute Builder.deps_include?([{:tailwind, "~> 0.2"}], :esbuild)
      refute Builder.deps_include?([], :tailwind)
    end
  end

  describe "create_tarball_remote/1" do
    test "tars the release directory on the build host" do
      cmd = Builder.create_tarball_remote(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "tar -czf ~/.xamal/builds/my-app/my_app-abc1234.tar.gz"
      assert cmd_str =~ "-C ~/.xamal/builds/my-app/_build/prod/rel/my_app"
    end
  end

  describe "remote_tarball_path/1" do
    test "returns the tarball path on the build host" do
      assert Builder.remote_tarball_path(@config) ==
               "~/.xamal/builds/my-app/my_app-abc1234.tar.gz"
    end
  end

  describe "build_in_docker/1" do
    test "builds docker run command with default image" do
      cmd = Builder.build_in_docker(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "docker run --rm"
      assert cmd_str =~ "-v $(pwd):/app"
      assert cmd_str =~ "-w /app"
      assert cmd_str =~ "hexpm/elixir"
      assert cmd_str =~ "sh -c"
    end

    test "uses custom image when docker is a string" do
      config = put_in(@config.builder, %Xamal.Configuration.Builder{docker: "my-org/elixir:1.18"})
      cmd = Builder.build_in_docker(config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "my-org/elixir:1.18"
      refute cmd_str =~ "hexpm/elixir"
    end

    test "includes build steps" do
      cmd = Builder.build_in_docker(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "command -v git"
      assert cmd_str =~ "apt-get update"
      assert cmd_str =~ "mix local.hex --if-missing --force"
      assert cmd_str =~ "mix local.rebar --if-missing --force"
      assert cmd_str =~ "MIX_ENV=prod mix deps.get --only prod"
      assert cmd_str =~ "MIX_ENV=prod mix deps.compile"
      assert cmd_str =~ "MIX_ENV=prod mix assets.deploy"
      assert cmd_str =~ "MIX_ENV=prod mix release my_app --overwrite"
      assert cmd_str =~ "chown -R"
    end

    test "omits tailwind/esbuild install steps when the project has neither dependency" do
      # Same reasoning as build_release_remote/1's equivalent test - xamal's
      # own project (which these tests run under) has neither dependency.
      cmd_str = @config |> Builder.build_in_docker() |> Enum.join(" ")

      refute cmd_str =~ "tailwind.install"
      refute cmd_str =~ "esbuild.install"
    end

    test "includes volume flags when configured" do
      config =
        put_in(@config.builder, %Xamal.Configuration.Builder{
          docker: true,
          volumes: ["xamal-hex-cache:/root/.hex", "xamal-mix-cache:/root/.mix"]
        })

      cmd = Builder.build_in_docker(config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "-v xamal-hex-cache:/root/.hex"
      assert cmd_str =~ "-v xamal-mix-cache:/root/.mix"
    end

    test "no volume flags when volumes is empty" do
      config = put_in(@config.builder, %Xamal.Configuration.Builder{docker: true, volumes: []})
      cmd = Builder.build_in_docker(config)
      cmd_str = Enum.join(cmd, " ")

      # Only the $(pwd):/app volume mount should appear before sh -c
      [before_sh | _] = String.split(cmd_str, "sh -c")
      volumes = Regex.scan(~r/-v\s+\S+/, before_sh)
      assert length(volumes) == 1
    end

    test "passes builder args as env flags" do
      config =
        put_in(@config.builder, %Xamal.Configuration.Builder{
          docker: true,
          args: %{"HEX_KEY" => "secret123", "MIX_DEBUG" => "1"}
        })

      cmd = Builder.build_in_docker(config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "-e HEX_KEY=secret123"
      assert cmd_str =~ "-e MIX_DEBUG=1"
    end

    test "no env flags when args is nil" do
      config = put_in(@config.builder, %Xamal.Configuration.Builder{docker: true, args: nil})
      cmd = Builder.build_in_docker(config)
      cmd_str = Enum.join(cmd, " ")

      # Should not have any -e flags (except inside the sh -c script)
      [before_sh | _] = String.split(cmd_str, "sh -c")
      refute before_sh =~ "-e "
    end

    test "no env flags when args is empty" do
      config = put_in(@config.builder, %Xamal.Configuration.Builder{docker: true, args: %{}})
      cmd = Builder.build_in_docker(config)
      cmd_str = Enum.join(cmd, " ")

      [before_sh | _] = String.split(cmd_str, "sh -c")
      refute before_sh =~ "-e "
    end
  end

  describe "unpack_tarball/1" do
    test "unpacks and removes tarball" do
      cmd = Builder.unpack_tarball(@config)
      cmd_str = Enum.join(cmd, " ")

      assert cmd_str =~ "tar -xzf"
      assert cmd_str =~ "/opt/xamal/my-app/releases/abc1234"
      assert cmd_str =~ "rm"
    end
  end
end
