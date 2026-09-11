# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres
to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- FreeBSD support: set `os: "freebsd"` to target rc.d + `daemon(8)` instead of
  systemd. Since rc.d has no template units, `mix xamal.server.bootstrap`
  generates two fixed per-port scripts up front instead of one template;
  each runs the release under `daemon(8) -R 5` for restart-on-failure
  (rc.d itself doesn't supervise processes) and enforces `drain_timeout`
  with a SIGKILL fallback on stop (rc.subr's default stop has no timeout of
  its own). Caddy installs via `pkg` instead of `apt`, and logs (both
  Caddy's and the release's) are tailed from log files instead of
  `journalctl`, which FreeBSD doesn't have. See `mix xamal.docs os`.
  `Xamal.Commands.Systemd` and the new `Xamal.Commands.RcD` are dispatched
  through `Xamal.Commands.Service` based on this setting; callers
  (`Xamal.AppTasks`, `Xamal.BlueGreen`, `Xamal.ServerTasks`, `Xamal.Remove`)
  no longer reference either backend directly.
- `ssh: [become: "doas"]` — every remote command that needs root now goes
  through a configurable privilege-escalation command instead of a hardcoded
  `sudo`, for hosts (common on FreeBSD) that only have `doas` installed. See
  `mix xamal.docs ssh`.
- `caddy: [extra_config:]` — raw Caddyfile text spliced into the generated
  site block alongside `reverse_proxy`, an escape hatch for anything xamal
  doesn't model directly (blocking by header/path, custom matchers, etc.).
  See `mix xamal.docs caddy`.
- `caddy: [manage_system_caddyfile:]` (default `true`) — set to `false` if
  you manage the system Caddyfile yourself (e.g. via separate provisioning);
  xamal then never touches it, only the per-service Caddyfile. See
  `mix xamal.docs caddy`.
- `ssh: [system_ssh: true]` — switches command execution, log streaming, and
  uploads from Erlang's `:ssh` stdlib to the system `ssh`/`scp` binaries.
  Erlang's `:ssh` never talks to `ssh-agent` unless explicitly wired to
  (xamal doesn't) and can't prompt for a passphrase (`user_interaction` is
  hardcoded off), so a passphrase-protected key that only `ssh-agent` can
  unlock fails every connection under the default transport. `system_ssh`
  picks up `SSH_AUTH_SOCK`, `~/.ssh/config`, and an already-unlocked agent
  the same way your regular `ssh` command does. Doesn't cover
  `mix xamal.iex`/`app.exec -i` (still Erlang `:ssh` regardless of this
  setting — a real interactive PTY over a shelled-out subprocess is a
  harder problem than running a command or streaming output). Incompatible
  with `ssh.key_data`, which has no system-ssh equivalent and is rejected
  together with `system_ssh` at config-load time. See `mix xamal.docs ssh`.
- `builder: [remote: "user@host"]` is now actually implemented — previously
  parsed and shown in `mix xamal.build.details`, but `mix xamal.build`
  silently built locally regardless of this setting. Source syncs to
  `~/.xamal/builds/<service>` on the build host via
  `git archive HEAD | ssh ... tar -x` (only committed files — matches what
  the deploy dirty-check already requires); `mix release` and the tarball
  step run there (needs Elixir/Erlang/Mix already installed, same as Docker
  mode needs Docker installed); the tarball is fetched back to the same
  local path a local/Docker build produces, so `mix xamal.build.upload`
  needs no changes. See `mix xamal.docs builder`.
- `caddy: [admin: "localhost:2020"]` — overrides the admin API address
  `reload`/`start`/`stop` assume when calling `caddy` directly (see the
  `CADDY_ADMIN` fix below). Unset, xamal guesses Caddy's own default on
  Linux or FreeBSD's `www/caddy` package default on FreeBSD — both wrong if
  something's changed the real admin address (a customized `caddy_admin` in
  `rc.conf`, a hand-written `admin` block in a Caddyfile outside xamal's
  control). See `mix xamal.docs caddy`.
- `release: [run_as: "..."]` — the OS account the release *process* runs
  as (systemd's `User=`, or the FreeBSD `daemon(8) -u` target), separate
  from `ssh.user` (who deploys/administers the host). Defaults to
  `ssh.user`, matching xamal's original one-account behavior. `ssh.user`
  typically has passwordless root via `become` for provisioning — a
  network-facing release process has no business inheriting that, so this
  lets it run under a distinct, unprivileged account instead. See
  `Xamal.Configuration.run_as_user/1`.
- `Xamal.Configuration.shared_directory/1` (`<service_dir>/shared`) is now
  wired up: each port instance gets its own `run_as`-owned subdirectory
  under it (`shared/<port>`), with `RELEASE_TMP` and Erlang's
  `ERL_CRASH_DUMP` pointed there on both systemd and rc.d. Everything else
  under `service_dir` (the release itself, env files, logs) is
  `ssh.user`-owned and not writable by `run_as` — this is the one place
  the running release can actually write to.

### Changed

- `mix xamal.server.bootstrap` no longer overwrites the system Caddyfile
  (`/etc/caddy/Caddyfile`, or `/usr/local/etc/caddy/Caddyfile` on FreeBSD).
  It now only ensures `import /opt/xamal/*/Caddyfile` is present, appending
  it if missing (and inserting a newline first if the file's last existing
  line didn't already end with one) — any global options block, other
  sites, or anything else you manage in that file yourself is left
  untouched. There's no xamal config for a global options block (e.g.
  `email`) — that's host-wide, not a per-service concern, so it's entirely
  up to whatever manages the file.
- Role env files are uploaded to every host before the `pre-app-boot` hook
  runs, rather than host by host during the boot itself. A `pre-app-boot`
  hook that talks to the release it is about to boot - running migrations
  against the newly distributed version, the usual reason to write one -
  needs the env file the release reads its configuration from, and on a
  first deploy to a fresh host nothing had written it yet, so the hook
  failed. Deploys across several hosts now stage every host env file
  before booting any of them.

### Fixed

- `Caddy.reload`/`Caddy.start` now target the system Caddyfile instead of
  the per-service one. `caddy reload --config <file>` replaces the entire
  live config with whatever `<file>` (and its imports) resolves to, so
  reloading from the per-service file — which has no imports of its own —
  was dropping every other site and any global options block from the
  *running* config on every deploy, not just at bootstrap. This dates back
  to xamal's initial commit.
- SSH command failures are no longer silently swallowed. Most deploy steps
  (blue-green swap, env file upload, `mix xamal.server.bootstrap`,
  `mix xamal.build.upload`, `mix xamal.remove`) discarded the result of
  `SSH.execute_command`/`on_hosts` entirely, so a failing step — a bad rc.d
  script, a permission error, a dropped connection — would leave the task
  printing success (`Bootstrapped <host>`, `Deployed to <host>`, `Removed!`)
  having done nothing, or half of something. New `SSH.execute_command!/3`,
  `Remote.ssh_exec!/3`, and `Remote.on_hosts!/2` raise immediately with the
  host, the command, and the underlying failure reason instead.
- `Caddy.reload`/`Caddy.start`/`Caddy.stop` now work on FreeBSD when Caddy is
  actually running. The `www/caddy` port's rc.d script defaults Caddy's admin
  API to a unix socket (`unix//var/run/caddy/caddy.sock`) and exports it as
  `CADDY_ADMIN` for every caddy subcommand it runs — but only when invoked
  *through* the rc.d script (`service caddy ...`). Calling the `caddy`
  binary directly, as these three do, doesn't inherit that, so they fell
  back to caddy's own default admin address (`localhost:2019`) — which
  nothing is listening on, since the real admin API is that socket. They
  now set the same `CADDY_ADMIN` themselves on FreeBSD.
- `mix xamal.redeploy`'s docs (`@moduledoc`/`@shortdoc`, and the README)
  said "deploy without bootstrapping" — misleading, since `mix xamal.deploy`
  doesn't bootstrap either (only `mix xamal.setup` does). The only actual
  difference between `deploy` and `redeploy` is that `redeploy` skips
  pruning old releases afterward; the docs now say that instead.
- `Builder.build_release_remote/1` (`builder.remote`) and `build_in_docker/1`
  (`builder.docker`) now run `mix tailwind.install`/`mix esbuild.install`
  under `MIX_ENV=prod`, like every other step in the same build. Without it
  they ran under Mix's default `:dev` env, and since the preceding
  `deps.get --only prod` deliberately never fetched `:dev`/`:test`-only
  deps, Mix refused to continue the moment either ran ("Unchecked
  dependencies for environment dev") — a real, reproducible failure for any
  project with dev/test-only deps, not a hypothetical.
- `Builder.build_release_remote/1` and `build_in_docker/1` now only run
  `mix tailwind.install`/`mix esbuild.install` when the project actually
  depends on `:tailwind`/`:esbuild`. Those Mix tasks are defined by the
  hex packages themselves, so calling them unconditionally broke any
  project that doesn't use one (or either) — e.g. a plain-CSS app with no
  JS bundler — with "The task ... could not be found", not just a
  no-op.
- FreeBSD: the rc.d `${name}_prestart()` hook now pre-creates
  `<service_dir>/log/<name>.log` owned by `ssh.user` (mode 640) before
  `daemon(8)` starts. `daemon(8)` opens its `-o` logfile while still
  running as root (it only drops to `-u <user>` for the child process), so
  a first boot left the file root-owned, mode 600 — unreadable by
  `mix xamal.app.logs`, which tails it as `ssh.user`, not root (surfaced
  as a silent "(no logs available)" rather than a permission error).
- `mix xamal.remove` now removes the service directory via `become`.
  `shared_directory/1`'s per-port subdirectories are `run_as`-owned (see
  above), so a plain `rm -r` as `ssh.user` could fail partway through
  whenever `run_as` differs from `ssh.user` — `ssh.user` can delete the
  now-empty subdirectory *entries* (it owns the parent), but not
  necessarily their *contents* first.
- `Commands.App.current_version/1` no longer reports a version for a
  `current` symlink that doesn't resolve to a release. `readlink -f`
  canonicalizes a *dangling* link rather than failing on it, so a `current`
  left pointing at, say, `<releases>/releases` reported the version
  "releases" — and `BlueGreen`'s failed-boot rollback fed that straight back
  into `link_current/2`, recreating the same broken link on every deploy
  that failed its health check, and leaving `mix xamal.app.*` pointing at a
  path with no release in it. It now checks that the resolved target is a
  directory directly under the releases directory and exits non-zero
  otherwise, which callers already report as an unknown version.
- The remote health check no longer assumes curl on FreeBSD, where it is not
  in the base system. On a host that had never installed it every poll
  failed with "command not found", which is indistinguishable from an app
  that never became healthy: the blue-green swap timed out and rolled back a
  release that was serving fine. `os: "freebsd"` now polls with fetch(1),
  which is in base; it cannot report a status code, so a successful request
  is mapped onto the "200" the poller compares against.

### Security

- The uploaded env file (`env/roles/<role>.env`, holding secrets like
  `SECRET_KEY_BASE`) is now `chmod 600` right after writing, instead of
  whatever the default umask left it as (typically world-readable). Both
  systemd and rc.d/`daemon(8)` read it as root, before dropping to
  `release.run_as`, to build the release's environment — so tightening
  this to owner-only doesn't affect the running release either way, on
  either backend.

## [0.4.2]

### Fixed

- `mix xamal.server.bootstrap` now writes the Caddyfile against the port that
  is actually serving, instead of always using `app_port`. Bootstrap is the
  only command that re-renders the systemd unit, so it gets run against live
  servers; on a server whose last blue-green deploy landed on `alt_port`, it
  previously repointed Caddy at the idle port and reloaded, causing an outage
  until the next deploy swapped back. The recorded port is used only when it
  is `app_port` or `alt_port`; otherwise it falls back to `app_port`.

## [0.4.1]

### Changed

- Interactive SSH sessions now use OTP 28's supported raw terminal mode
  (`:shell.start_interactive({:noshell, :raw})`) when available, instead of
  taking over fd 0 with a port. This removes the "stealing control of fd=0"
  path on newer OTP releases. OTP 26/27 keep the previous fd/stty approach as
  a fallback, which now also handles macOS/BSD `stty -f`.

## [0.4.0]

### Changed

- **Renamed the build tasks** away from the registry-derived `push`/`pull`
  verbs, which were misleading for a tarball-over-SSH workflow (nothing is
  pushed to a registry, and "pull" actually uploaded to the server):
  - `mix xamal.build.push` → `mix xamal.build` (build the tarball locally)
  - `mix xamal.build.pull` → `mix xamal.build.upload` (upload the tarball to servers)
  - `mix xamal.build.deliver` and `mix xamal.build.details` are unchanged.
  - The `--skip-push` deploy option is renamed to `--skip-build` (it skips the
    build and uploads an existing tarball). These are hard renames with no
    deprecation aliases.

### Added

- `CONTRIBUTING.md` documenting the development workflow, the `## [Unreleased]`
  changelog convention, and the maintainer release process.

## [0.3.2]

### Changed

- Release tarballs now upload via the system `scp` binary when an on-disk SSH
  key (`ssh.keys`) is configured, instead of Erlang's SFTP channel. SFTP's small
  window made large transfers slow (observed ~9 min for a ~120 MB tarball); scp
  runs at full link speed. Flows without an on-disk key (`key_data` from a
  secrets manager, or an SSH agent) continue to use the in-VM SFTP channel, as
  does the fallback when no `scp` binary is present.

### Fixed

- The release workflow no longer fails when a changelog entry contains
  backticks or `$()`. Release notes are now passed to `gh release create` via
  `--notes-file` instead of being interpolated into the command, so shell
  metacharacters in the notes are not executed.

## [0.3.1]

### Fixed

- Per-task flags are no longer rejected when they lead the arguments. Commands
  like `mix xamal.app.logs -f` (and `-n`, `--since`, `--grep`) failed with
  `Unknown option`; the global option parser now forwards unrecognized flags to
  the task instead of raising.
- Remote commands keep their own flags. `mix xamal.server.exec df -h /` no
  longer has `-h /` consumed as the global `--hosts` option; option scanning
  stops at the first positional argument.
- `mix xamal.app.exec` no longer drops command flags other than `-i`.
- Interactive SSH sessions (`mix xamal.app.exec -i`, `mix xamal.iex`) resolve
  the real terminal device instead of assuming `/dev/tty` is openable, so they
  work when the BEAM runs without a controlling terminal.
- `mix xamal.rollback` no longer prints its "no previous version" error twice.

### Added

- `--skip-push` deploy option to distribute an already-built release instead of
  rebuilding.

### Removed

- `mix xamal.shell`. It mirrored Kamal's `shell` (a bash session inside the
  running container), but Xamal deploys native releases on the host, so it only
  duplicated `mix xamal.iex`. Use `mix xamal.iex` for a remote console or
  `mix xamal.server.exec` for host commands.

## [0.3.0]

See [UPGRADING.md](UPGRADING.md) for step-by-step migration instructions.

### Added

- New `mix xamal.prune` task to remove old releases beyond the retained count.
- New `mix xamal.shell` and `mix xamal.iex` tasks to open a remote shell or IEx
  session against the running release.
- New `mix xamal.migrate` task to run the release migrator (`<App>.Release.migrate`).
- New `mix xamal.server.logs` task to show Caddy/proxy logs from servers.
- New `mix xamal.app.start` task to start the service on its active port without a swap.
- New `mix xamal.app.version` task to show the deployed version per host.
- New `mix xamal.app.stale_releases` task to preview releases that pruning would remove.
- New `mix xamal.version` task to print the installed Xamal version.
- Hex packaging metadata, badges, and HexDocs configuration.

### Changed

- **Breaking:** Replaced the escript CLI with Mix tasks (`mix xamal.*`) as the
  public command surface. Invoke commands via `mix xamal.<task>` instead of the
  previous `xamal` escript binary, and install Xamal as a Mix dependency rather
  than a standalone binary.
- **Breaking:** Configuration is now Elixir config in `config/xamal.exs` instead
  of `config/deploy.yml`, with destination overrides in
  `config/xamal/<destination>.exs`. EEx templating is replaced by plain Elixir
  expressions (e.g. `System.get_env/1`).
- Mix tasks are grouped under a "Mix Tasks" section in the generated docs.

### Removed

- The `xamal` escript binary and the `install.sh` installer that downloaded it.

## [0.2.0]

### Changed

- Internal refactors toward the Mix-first architecture. No user-facing changes.

## [0.1.0]

### Added

- Initial release.

[0.4.1]: https://github.com/dmkenney/xamal/releases/tag/v0.4.1
[0.4.0]: https://github.com/dmkenney/xamal/releases/tag/v0.4.0
[0.3.2]: https://github.com/dmkenney/xamal/releases/tag/v0.3.2
[0.3.1]: https://github.com/dmkenney/xamal/releases/tag/v0.3.1
[0.3.0]: https://github.com/dmkenney/xamal/releases/tag/v0.3.0
[0.2.0]: https://github.com/dmkenney/xamal/releases/tag/v0.2.0
[0.1.0]: https://github.com/dmkenney/xamal/releases/tag/v0.1.0
