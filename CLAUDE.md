# CLAUDE.md

Project context for Claude Code.

## Project Purpose

**config-weave-pkgs** is the standard package library for Config Weave: Linux,
Windows and SQL Server. It is a pure data/content repo — no Rust, no build. The
authoritative reference for what each package offers is `README.md`; read it
before adding or changing a package.

Config Weave v1 loads packages from a playbook's local `pkgs/` directory only,
so this library is vendored into a playbook by copying or symlinking individual
`pkgs/<name>` directories. That is deliberate: it requires no loader changes.

## Layout

Every package follows the same fixed layout — wscript sources use the `.ws`
extension, matching config-weave and vmlab:

```
pkgs/<name>/
  package.wcl               # resource, gatherer and test declarations
  resources/<r>.ws          # exports check() and apply()
  gatherers/<g>.ws          # exports gather()
  tests/<t>.ws              # optional verify() / scenario drivers
```

`playbook.wcl` at the root is the validation/documentation harness only — two
`gather` blocks and one container-safe `baseline` play. It is not part of the
public docs surface, which is why every docs command passes `--pkg-only`.

`weave.wscripti` and `wscript.toml` give the wscript LSP the exact host API.
Regenerate them with `just wscripti` after a config-weave upgrade — it rewrites
both tracked files, so never run it inside a check pipeline.

Rendered docs (`docs/`) are generated from `package.wcl` metadata and are
gitignored, so a package's documentation *is* its doc cells in `package.wcl`.

## Conventions

- Ticket-branch development, driven by the aciddog kanban board: work happens
  on a branch named for the ticket id (`t-…`) in that ticket's worktree at
  `.tree/<ticket-id>`, and lands on `main` through a pull request. Never commit
  or push directly to `main` — the board's Tests and Review stages gate every
  change, and a direct push bypasses them.
- **Removal is `ensure = :absent`** on the same resource that creates the thing.
  Every install/remove resource takes an `ensure` param (`:present`, the
  default, or `:absent`) instead of a separate `*_absent` resource. `ensure` is
  a **symbol**, so it must be written `:absent` — the string spelling
  `"absent"` is a validation error. Every symbol param declares its legal
  values.
- **just** as command runner: `just check` (== `just validate`) is the cheap,
  unattended-safe gate — pure WCL parse, schema check and wscript compile, with
  no network, VM or sudo.
- The `config-weave` binary comes from `PATH` (`just install-tool` installs it
  from GitHub). Override it to develop the two repos together:
  `CONFIG_WEAVE=../config-weave/target/debug/config-weave just check`.
- Conventional Commits, scoped by package (`feat(windows_iis): …`,
  `fix(tests): …`), with `!` for breaking changes. This library breaks
  compatibility often and marks it.

## Testing

`just test` **unfiltered runs everything** — 78 test declarations, of which 45
are `image =` vmlab containers (Linux, seconds) and 33 are `template =` full VMs
with real init and reboots, Linux *and* Windows. It needs vmlab, KVM and the
templates the VM tests name, so it is not safe to run unattended.

Scope it with a filter instead: `just test linux_files` for a whole package, or
`just test mssql:config_converges` for a single test.

This repo has no CI of its own; `just check` is run for it on a schedule from
the aciddog workspace, which files a ticket when it fails.
