# Agents

## Project

Xamal is a Mix-first Elixir deployment tool for bare-metal Elixir releases over SSH. It is inspired by Kamal, but uses native releases, Caddy, and Elixir configuration instead of Docker, kamal-proxy, and YAML.

## Stack

- Elixir 1.15+, OTP 26+
- Mix tasks (`mix xamal.*`) are the public command surface
- Elixir config via `config/xamal.exs`
- Destination overrides live under `config/xamal/<destination>.exs`
- SSH via Erlang `:ssh` stdlib
- Tests: `mix test` (ExUnit)
- Quality checks: `mix ci`

## Architecture

- `lib/mix/tasks/` — public Mix task entrypoints, usually `use Xamal.MixTask` for config-loading tasks
- `lib/xamal/deployment.ex` — high-level deploy/redeploy/setup/rollback orchestration
- `lib/xamal/*_tasks.ex`, `prune.ex`, `audit.ex`, `details.ex`, `remove.ex`, `versions.ex` — task implementations used by Mix tasks
- `lib/xamal/output.ex`, `hooks.ex`, `remote.ex`, `deploy_lock.ex`, `blue_green.ex`, `logs.ex`, `task_helpers.ex` — runtime helpers for output, hooks, SSH execution, locking, blue-green boot, logs, and task concerns
- `lib/xamal/secrets/adapters/` — secret-manager adapter implementations used by `Xamal.SecretTasks`
- `lib/xamal/commands/` — pure functions returning command lists (`["cmd", "arg1"]`), composed with `combine/pipe/chain`
- `lib/xamal/commands/service.ex` — dispatches to `systemd.ex` (Linux, default) or `rc_d.ex` (FreeBSD, `os: "freebsd"`); callers use this, never the backends directly
- `lib/xamal/configuration/` — structs with `new/1` constructors parsing Elixir config data
- `lib/xamal/context.ex` — explicit runtime context for config, host/role filters, verbosity, lock, and connection state

## Conventions

- Prefer Mix tasks over custom CLI dispatch.
- Do not add an escript entrypoint.
- Do not introduce `Xamal.CLI.*` modules; command behavior belongs in `Xamal.*` modules or Mix tasks.
- Command builder modules return list-of-strings and never execute anything.
- Config structs are immutable and built from Elixir config.
- Prefer Mix aliases in host `mix.exs` over custom command aliases in Xamal config.
- Hooks run locally, not on remote servers.
- Run `mix ci` before considering a change complete.

## Commit messages

- No AI attribution in commit messages — no "Co-Authored-By", no mentioning Claude, Copilot, ChatGPT, or any AI tool
- Keep messages short and descriptive
- Use imperative mood ("Add feature" not "Added feature")
