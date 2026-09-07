defmodule Xamal.Docs do
  @moduledoc """
  Inline configuration documentation viewer.
  """

  def run(args) do
    case args do
      [] -> print_topics()
      [topic | _] -> print_topic(topic)
    end
  end

  defp print_topics do
    IO.puts("""
    Xamal Configuration Reference

    Usage: mix xamal.docs <topic>

    Topics:
      config          config/xamal.exs overview and structure
      servers         Server and role configuration
      os              Target server OS (systemd vs. rc.d/FreeBSD)
      ssh             SSH connection options
      caddy           Caddy reverse proxy and TLS
      env             Environment variables (clear and secret)
      release         Elixir release settings
      health_check    Health check configuration
      boot            Rolling deploy options (limit, wait)
      builder         Build configuration (local, docker, remote)
      hooks           Hook scripts (lifecycle events)
      secrets         Secrets management and adapters
      destinations    Multi-environment destinations
    """)
  end

  defp print_topic("config") do
    IO.puts("""
    # config/xamal.exs Configuration

    Xamal reads Elixir configuration from `config/xamal.exs` (or a custom path via -c).
    Since this is a normal config file, you can use Elixir expressions:

      import Config

      config :xamal,
        service: System.get_env("SERVICE_NAME") || "my-app",
        servers: [web: ["192.168.0.1"]]

    ## Top-level keys

      :service            App name (required)
      :servers            Server/role definitions (required)
      :os                 Target server OS: "linux" (default) or "freebsd"
      :ssh                SSH connection options
      :caddy              Reverse proxy configuration
      :env                Environment variables
      :release            Elixir release settings
      :health_check       Health check configuration
      :boot               Rolling deploy options
      :builder            Build configuration
      :hooks_path         Path to hook scripts (default: .xamal/hooks)
      :secrets_path       Path to secrets file (default: .xamal/secrets)
      :readiness_delay    Seconds to wait before health checks (default: 7)
      :deploy_timeout     Max deploy time in seconds (default: 30)
      :drain_timeout      Seconds to drain old release (default: 30)
      :retain_releases    Number of old releases to keep (default: 5)
      :primary_role       Primary role name (default: web)
    """)
  end

  defp print_topic("servers") do
    IO.puts("""
    # Server Configuration

    ## Simple (hosts only)

      servers:
        web:
          - 192.168.0.1
          - 192.168.0.2

    ## Extended (with role options)

      servers:
        web:
          - 192.168.0.1
        worker:
          hosts:
            - 192.168.0.3
          cmd: bin/my_app eval "Worker.start()"
          env:
            clear:
              WORKER_MODE: "true"

    ## Tags

      servers:
        web:
          hosts:
            - 192.168.0.1
          tags:
            region: us-east

    The primary role (default: "web") is used for lock management and
    single-host operations like `mix xamal.app.exec`.

    All hosts for a given destination must run the same OS — see
    `mix xamal.docs os`.
    """)
  end

  defp print_topic("os") do
    IO.puts("""
    # Target Server OS

      os: "linux"      # default: systemd + journalctl
      os: "freebsd"     # rc.d + daemon(8), no journal

    Selects the service-manager backend `mix xamal.server.bootstrap` and
    `mix xamal.app.boot` use to run the release, and (on FreeBSD) how Caddy
    is installed and its logs are read. It's a single destination-wide
    setting — see `mix xamal.docs destinations` if staging and production
    run different OSes.

    ## linux (systemd)

    One template unit (`<release>@.service`), instantiated per port
    (`<release>@4000`, `<release>@4001`). Crash recovery via
    `Restart=on-failure`; logs via `mix xamal.app.logs` / `mix xamal.server.logs`
    (journalctl).

    ## freebsd (rc.d + daemon(8))

    rc.d has no template units, so bootstrap generates two fixed scripts up
    front instead — one per blue-green port
    (`/usr/local/etc/rc.d/<release>_4000`, `..._4001`). Each runs the release
    under `daemon(8)` for restart-on-failure (`-R 5`, matching systemd's
    `RestartSec=5`); stopping enforces `drain_timeout` before escalating to
    SIGKILL, since rc.subr's own stop has no such timeout.

    There's no journal: output goes to `<service_dir>/log/<release>_<port>.log`,
    which `mix xamal.app.logs` tails instead. `--since` has no effect on
    FreeBSD logs (no journalctl equivalent for filtering by timestamp).

    Caddy installs via `pkg` instead of `apt`, and its own logs come from
    `/var/log/caddy/caddy.log` (the `www/caddy` package's default) rather
    than journalctl.
    """)
  end

  defp print_topic("ssh") do
    IO.puts("""
    # SSH Configuration

      ssh:
        user: deploy          # SSH user (default: root)
        become: doas          # Privilege escalation command (default: sudo)
        system_ssh: true      # Shell out to system ssh/scp (default: false)
        port: 22              # SSH port (default: 22)
        proxy: jump-host      # SSH proxy/jump host
        keys: ["~/.ssh/id_ed25519"]  # Specific key files
        keys_only: true       # Only use specified keys

    SSH connections use Erlang's :ssh stdlib with connection pooling by
    default. Connections are reused across commands and time out after 900s
    idle.

    ## become

    Prefixed onto every remote command that needs root (installing service
    units, writing to /opt, reloading Caddy, etc). Defaults to "sudo"; set to
    "doas" on hosts that use OpenBSD's doas instead — common on FreeBSD boxes
    that don't install sudo at all. Can include arguments, e.g. "doas -u root".

    ## system_ssh

    Switches command execution and uploads from Erlang's :ssh stdlib to the
    system ssh/scp binaries. Erlang's :ssh never talks to ssh-agent unless
    explicitly wired to (xamal doesn't), and can't prompt for a passphrase
    (user_interaction is hardcoded off) — so a passphrase-protected key that
    only ssh-agent can unlock fails every connection under the default
    transport, even though your own `ssh`/`scp` commands work fine with an
    already-unlocked agent. Turning this on picks up SSH_AUTH_SOCK, your
    ~/.ssh/config, and an unlocked agent the same way your regular ssh
    command does — nothing else about your config needs to change.

    Covers: mix xamal.server.bootstrap, mix xamal.deploy, mix xamal.app.*,
    mix xamal.build.upload, mix xamal.server.logs, mix xamal.app.logs -f —
    effectively everything except `mix xamal.iex` / `mix xamal.app.exec -i`,
    which still use Erlang's :ssh regardless of this setting (an
    interactive PTY over a shelled-out subprocess is a harder problem than
    running a command or streaming its output).

    Authentication itself is out of xamal's hands once this is on — it's
    exactly whatever `ssh user@host` already does for you in a terminal.
    `ssh.keys`/`keys_only`/`proxy`/`proxy_command`/`config` still map onto
    the equivalent `-i`/`-o IdentitiesOnly=yes`/`-J`/`-o ProxyCommand=`/`-F`
    flags; `ssh.key_data` (raw key material for a secrets-manager flow) has
    no system-ssh equivalent and is rejected together with `system_ssh` at
    config-load time.
    """)
  end

  defp print_topic("caddy") do
    IO.puts("""
    # Caddy Configuration

      caddy:
        host: app.example.com       # Domain for auto-TLS (Let's Encrypt)
        app_port: 4000              # Port the Elixir app listens on (default: 4000)

    ## Multiple domains

      caddy:
        host: app.example.com
        hosts:
          - www.example.com

    Caddy automatically provisions TLS certificates via Let's Encrypt.
    During deploys, Caddy switches between app_port and app_port+1
    for zero-downtime blue-green deployments.

    The generated Caddyfile lives at /opt/xamal/<service>/Caddyfile.

    ## The system Caddyfile

    `mix xamal.server.bootstrap` ensures the system Caddyfile
    (/etc/caddy/Caddyfile, or /usr/local/etc/caddy/Caddyfile on FreeBSD)
    contains:

      import /opt/xamal/*/Caddyfile

    appending that line only if it's missing — nothing else in the file is
    touched or overwritten. Every xamal-managed service's Caddyfile is
    picked up by the same wildcard, so this is safe to run from multiple
    services on one host without any of them stepping on each other.

    Anything else that belongs in that file — a global options block
    (`email`, custom `http_port`/`https_port`, etc), other sites — is
    host-wide, not a per-service concern, so there's no xamal config for it.
    Manage it yourself directly in the system Caddyfile.

    ## manage_system_caddyfile

      caddy:
        manage_system_caddyfile: false   # default: true

    Set to false if you don't want xamal touching the system Caddyfile at
    all — not even to ensure the import line. `mix xamal.server.bootstrap`
    still writes the per-service Caddyfile at /opt/xamal/<service>/Caddyfile,
    but you're responsible for adding `import /opt/xamal/*/Caddyfile` to
    your own Caddyfile yourself.

    ## extra_config

      caddy:
        extra_config: |
          @blocked {
              header User-Agent "*BadBot*"
          }
          respond @blocked 403

          @admin path /admin/*
          respond @admin 404

    Raw Caddyfile text spliced into the generated site block alongside
    reverse_proxy — the escape hatch for anything not modeled directly here
    (request blocking by header/path, custom matchers, rate limiting, etc).
    Caddy orders recognized directives by its own fixed priority regardless
    of where they appear in the block, so placement relative to reverse_proxy
    doesn't matter for common directives like respond; wrap in an explicit
    `route { }` if you need strict textual ordering.

    ## Maintenance mode

      mix xamal.app.maintenance    # Serve 503 responses
      mix xamal.app.live           # Restore normal traffic
    """)
  end

  defp print_topic("env") do
    IO.puts("""
    # Environment Variables

      env:
        clear:
          PHX_HOST: app.example.com
          DATABASE_URL: ecto://...
        secret:
          - SECRET_KEY_BASE
          - DATABASE_PASSWORD

    Clear values are stored in config/xamal.exs. Secret values are loaded
    from .xamal/secrets (dotenv format) and uploaded to each server.

    Secret files support command substitution:

      SECRET_KEY_BASE=$(op read "op://Vault/Item/Field")

    Environment files are uploaded per-role to:
      /opt/xamal/<service>/env/roles/<role>.env
    """)
  end

  defp print_topic("release") do
    IO.puts("""
    # Release Configuration

      release:
        name: my_app          # Mix release name (default: service name underscored)
        mix_env: prod         # Mix environment (default: prod)

    The release name should match your mix.exs release configuration.
    Xamal builds with `MIX_ENV=<mix_env> mix release <name>` and
    packages the result as a tarball for distribution.
    """)
  end

  defp print_topic("health_check") do
    IO.puts("""
    # Health Check Configuration

      health_check:
        path: /health         # HTTP path to poll (default: /health)
        interval: 1           # Seconds between checks (default: 1)
        timeout: 30           # Max seconds to wait (default: 30)

    During deploys, Xamal polls the new release's health check endpoint
    before switching traffic. The app must return HTTP 200 on this path.

    Tip: Use Phoenix's built-in health check or add a simple plug:

      get "/health", fn conn, _ -> send_resp(conn, 200, "ok") end
    """)
  end

  defp print_topic("boot") do
    IO.puts("""
    # Boot/Rolling Deploy Configuration

      boot:
        limit: 10             # Max hosts to boot simultaneously
        wait: 2               # Seconds between batches

    By default, all hosts boot in parallel. Set `limit` to roll out
    gradually. The `wait` option adds a pause between batches.

    Example: With 20 servers and limit=5, hosts boot in 4 batches
    of 5, with a 2-second pause between each batch.
    """)
  end

  defp print_topic("builder") do
    IO.puts("""
    # Builder Configuration

      builder:
        local: true           # Build on dev machine (default)

    ## Docker cross-compilation

      builder:
        docker: true          # Build inside Docker container

    ## Remote build

      builder:
        remote: build@build-server

    The default local builder runs `mix release` on your dev machine.
    Use Docker mode when your dev OS differs from the server OS.
    Remote mode builds on a dedicated build server via SSH.
    """)
  end

  defp print_topic("hooks") do
    IO.puts("""
    # Hook Scripts

    Hooks are shell scripts in .xamal/hooks/ (configurable via hooks_path).
    They run on the LOCAL machine, not on servers.

    ## Supported hooks

      pre-build             Before building the release
      post-build            After building the release
      pre-deploy            Before deploying
      post-deploy           After deploying
      pre-app-boot          Before booting the app across roles
      post-app-boot         After booting the app across roles
      pre-caddy-reload      Before writing Caddyfile and reloading Caddy
      post-caddy-reload     After Caddy reload completes

    ## Hook environment variables

      XAMAL_SERVICE           Service name
      XAMAL_VERSION           Version being deployed
      XAMAL_HOSTS             Comma-separated host list
      XAMAL_ROLE              Current role
      XAMAL_DESTINATION       Destination name
      XAMAL_COMMAND           Current command (e.g. "deploy")
      XAMAL_SUBCOMMAND        Current subcommand (e.g. "app")
      XAMAL_RECORDED_AT       ISO 8601 timestamp of hook invocation
      XAMAL_PERFORMER         Git user name + email, or system username
      XAMAL_SERVICE_VERSION   "service@version" identifier
      XAMAL_LOCK              "true" if deploy lock is held, "false" otherwise

    ## Skipping hooks

      mix xamal.deploy --skip-hooks
      mix xamal.deploy -H
    """)
  end

  defp print_topic("secrets") do
    IO.puts("""
    # Secrets Management

    Secrets are loaded from dotenv files:

      .xamal/secrets-common       Shared across all destinations
      .xamal/secrets              Default secrets
      .xamal/secrets.<dest>       Destination-specific secrets

    ## Format

      # Comments start with #
      SECRET_KEY_BASE=my_secret_value
      QUOTED_VALUE="value with spaces"
      FROM_VAULT=$(op read "op://Vault/Item/Field")

    ## Fetching from external sources

      mix xamal.secrets.fetch 1password <vault> <item> <field>
      mix xamal.secrets.fetch aws_secrets_manager [--from PREFIX] SECRET
      mix xamal.secrets.fetch bitwarden --account EMAIL ITEM
      mix xamal.secrets.fetch doppler <project> <config>
      mix xamal.secrets.fetch gcp_secret_manager [--account USER] SECRET
      mix xamal.secrets.fetch last_pass --account EMAIL SECRET
      mix xamal.secrets.fetch passbolt [--from FOLDER] SECRET

    ## Viewing secrets

      mix xamal.secrets.print       # Show all (values redacted)
      mix xamal.secrets.extract KEY  # Show single value (unredacted)
    """)
  end

  defp print_topic("destinations") do
    IO.puts("""
    # Destinations (Multi-Environment)

    Destinations let you deploy to different environments (staging, production)
    from the same config base.

      config/xamal.exs                Base configuration
      config/xamal/staging.exs        Staging overrides
      config/xamal/production.exs     Production overrides

    ## Usage

      mix xamal.deploy -d staging
      mix xamal.deploy -d production

    Destination files are deep-merged over the base config. Only include
    keys you want to override:

      # config/xamal/staging.exs
      import Config

      config :xamal,
        servers: [web: ["staging.example.com"]],
        caddy: [host: "staging.example.com", app_port: 4000]

    Secrets also support destinations:

      .xamal/secrets.staging
      .xamal/secrets.production
    """)
  end

  defp print_topic(topic) do
    IO.puts("Unknown topic: #{topic}")
    print_topics()
  end
end
