# config-weave-pkgs

Standard package library for Config Weave: Linux, Windows and SQL Server.

This repository is meant to live next to `config-weave` and be vendored into
playbooks by copying or symlinking selected package directories:

```sh
mkdir -p ./pkgs
ln -s /home/wil/dev/config-weave-pkgs/pkgs/linux_files ./pkgs/linux_files
ln -s /home/wil/dev/config-weave-pkgs/pkgs/linux_facts ./pkgs/linux_facts
```

Config Weave v1 loads packages from a playbook's local `pkgs/` directory only,
so this repository intentionally does not require Config Weave loader changes.

Every package follows the same layout — wscript sources use the `.ws`
extension, matching config-weave and vmlab:

```
pkgs/<name>/
  package.wcl               # resource, gatherer and test declarations
  resources/<r>.ws          # exports check() and apply()
  gatherers/<g>.ws          # exports gather()
  tests/<t>.ws              # optional verify() / scenario drivers
```

`weave.wscripti` and `wscript.toml` in the repo root give the wscript LSP the
exact host API; regenerate them with `just wscripti` after a config-weave
upgrade.

## Packages

Removal is expressed with `ensure = :absent` on the same resource that
creates the thing — every install/remove resource takes an `ensure` param
(`:present`, the default, or `:absent`) instead of a separate `*_absent`
resource. `ensure` is a symbol, so it must be written `:absent`; the string
spelling `"absent"` is a validation error. Each resource's page lists the
legal values under **Symbol values**.

- `linux_facts`: Linux OS, init system, services, mounts and network facts.
- `linux_files`: files (exact content or URL-fetched), directories,
  symlinks/hard links, archives and modes.
- `linux_packages`: the package-manager detection gatherer.
- `linux_apt` / `linux_dnf` / `linux_pacman` / `linux_apk` / `linux_zypper` /
  `linux_flatpak`: one package per package manager — install, cache refresh
  and, where the manager supports them, repositories, keys and holds
  (`linux_pacman` also installs AUR packages via yay/paru).
- `linux_systemd` / `linux_openrc` / `linux_runit` / `linux_sysvinit`: one
  `service` resource per init system covering the service script/unit, boot
  enablement and running state, with `ensure = :absent` removing the service
  outright (systemd also has `unit_file` for timers, sockets and other unit
  types).
- `linux_accounts`: users, groups and per-user sudo rules.
- `linux_ssh`: authorized keys, known hosts and ssh/sshd config drop-ins.
- `git`: global and system git config — typed resources per section
  (`user`, `core`, `commit`, `push`, `pull`, `fetch`, `merge`, `diff`,
  `rebase`, `init`, `status`, `log`, `color`), plus `alias`,
  `safe_directory` and `config_entry` for anything else. Shells out to
  `git config`, so the target needs git installed.
- `linux_system`: sysctl, hostname, timezone, locales, cron and fstab.
- `linux_network`: hosts entries, firewalld/ufw rules and nftables
  tables/chains/rules.
- `linux_kde`: KDE Plasma KConfig entries.

Windows packages (`windows_installers`, `windows_packages`, `windows_features`,
`windows_registry`, `windows_updates`, `windows_domain`, `windows_sysprep`,
`windows_account`,
`windows_service`, `windows_network`, `windows_share`, `windows_files`,
`windows_defender`, `windows_iis`, `windows_powershell`) and the
cross-platform `mssql` package round out the library.

### `linux_files`

Files, directories, links, archives and modes. 6 resources and 2 gatherers:

- `file` — exact `content`, or fetched from `url`. Writes go to a temp file
  beside the target and are renamed into place, keeping the old file's owner
  and mode unless `mode`/`owner`/`group` say otherwise. A download is
  verified against `sha256` before it replaces anything. Without `sha256`, a
  url is fetched once and never re-checked, so set it whenever the content
  matters.
- `template` — a Tera template rendered the same way as `file`; takes
  `ensure`.
- `directory` — creates missing parents. `:absent` is recursive and refuses
  `/` and every top-level directory.
- `symlink` — symbolic or hard links. A dangling link at `path` is replaced,
  and a symlink may point at a target that does not exist yet.
- `archive_extracted` — extracts a local `.zip`/`.tar.gz` into `dest` and
  records the archive's SHA-256 in `dest/.config-weave-archive`, so a changed
  archive is extracted again. `owner`/`group`/`file_mode`/`dir_mode` apply to
  the whole tree; `:absent` deletes `dest`.
- `permissions` — owner, group and mode on an existing path (not recursive).
- `path_stat` and `paths_matching` gatherers. `path_stat` describes the path
  itself and never follows a symlink; `mode` is the permission bits (420 for
  0644).

Paths must be absolute and free of `..`. `mode` is 3 or 4 octal digits;
`owner` and `group` take a name or a numeric id. Every resource follows a
symlink at `path` for content and attributes, so `mode` on a symlinked path
changes the target.

### `linux_system`

Core system settings. 6 resources:

- `sysctl` — sets the value now and persists it in its own
  `/etc/sysctl.d/99-config-weave-<key>.conf`. Multi-value keys compare field
  by field. `:absent` deletes the drop-in and leaves the running value until
  the next boot.
- `hostname` — `/etc/hostname` and the running hostname (RFC 1123 names).
- `timezone` — `/etc/localtime`, plus `/etc/timezone` where it exists. Uses
  `timedatectl` only when systemd is PID 1, and an unknown zone is an error.
- `locale` — enables the `/etc/locale.gen` line and runs `locale-gen` where
  that exists (Debian, Ubuntu, Arch), and uses `localedef` elsewhere (RHEL,
  Fedora: needs `glibc-locale-source` or a `glibc-langpack-*`). With
  neither, it errors. `:absent` comments the line out.
- `cron_job` — one `/etc/cron.d/<name>` file per job. Names are
  `[A-Za-z0-9_-]+` (cron ignores any other file name), and a literal `%` in
  `command` must be written `\%`.
- `fstab_mount` — exactly one fstab entry per mount point, written through a
  temp file. With `mount = true` it also keeps the mount live: it creates the
  mount point, mounts it, remounts when the options change, and unmounts
  before `:absent` removes the entry.

### `linux_facts`

OS facts as gatherers: `os_release` (with `/usr/lib/os-release` as
fallback), `init_system`, `network`, `services` and `mounts`.
`init_system` reads PID 1, so a container whose PID 1 is an entrypoint
reports `:unknown`. `network.network_system` is a symbol (`:netplan`,
`:network_manager`, `:systemd_networkd`, `:wicked`, `:ifupdown`,
`:unknown`), and a daemon counts as running under any init system, not
only when systemd reports it. `services` includes installed unit files that
are not loaded, each with an `enabled` state.

### `windows_powershell`

PowerShell itself, as convergent resources — installing it, and every setting
it reads. 26 resources and 6 gatherers. Shared helpers (choosing and running a
PowerShell, quoting, validation, profile blocks, `powershell.config.json`, the
policy keys) live in `pkgs/windows_powershell/lib/`.

- `pwsh_installed` — install or remove PowerShell 7 by `:msi`, `:winget` or
  `:zip` on Windows and `:repo` or `:tarball` on Linux. The archive methods
  extract into a root named for the full version by default
  (`/opt/microsoft/powershell/7.5.4`), mark it as theirs, and refuse to
  overwrite or delete a root the MSI or a distro package owns — which is what
  makes them the only side-by-side-capable ones. `:repo` pins the package to
  `version`. `:msi` with `ensure = :absent` removes only the requested
  channel, by product code from the Uninstall key. The MSI method carries the
  documented properties (`add_path`, `enable_remoting`, `register_manifest`,
  the two context-menu items, Microsoft Update) and reports `RebootRequired`
  on msiexec 3010.
- `psremoting` and `session_configuration` — the WinRM endpoints. Which
  endpoint `Enable-PSRemoting` registers depends on the PowerShell that runs
  it, so `edition` is what picks between `microsoft.powershell` and
  `PowerShell.7` rather than a name the caller has to know.
  `session_configuration` compares every setting on an existing endpoint —
  access mode, startup script, size limit, PSVersion, session type and the
  `.pssc` content — and re-registers one that drifted. PowerShell 7
  endpoints take no `psversion` or `session_type`.
- `config_setting`, `module_path`, `experimental_feature`, `win_compat` and
  `log_setting` — `powershell.config.json`. `config_setting` is the generic
  escape hatch: a dotted key path, or `literal_key` for a module-qualified
  key such as `Microsoft.PowerShell:ExecutionPolicy`. All take a `path`
  override, which is what lets them run on a machine with no PowerShell 7
  installed at all. `log_setting` writes the all-users file only (the only
  one PowerShell reads for logging), with `LogChannels` and `LogKeywords` as
  the comma-separated strings PowerShell parses.
- `execution_policy`, `script_block_logging`, `module_logging`,
  `transcription`, `protected_event_logging` and
  `console_session_configuration` — what `Set-ExecutionPolicy` writes and
  the PowerShell Group Policy settings, driven through the `registry` host
  module. `edition` picks the policy key: Windows PowerShell 5.1 reads
  `…\Policies\Microsoft\Windows\PowerShell`, PowerShell 7 reads
  `…\Policies\Microsoft\PowerShellCore`. Two exceptions: PowerShell 7 keeps
  the `:local_machine` and `:current_user` execution policies in
  `powershell.config.json`, and protected event logging is one key under
  `…\Policies\Microsoft\Windows\EventLog` for both editions. The console
  session configuration policy exists for PowerShell 7 only. Every switch
  takes `ensure`, and a policy never written already satisfies `:absent`.
- `profile`, `profile_snippet`, `psreadline_option`,
  `psreadline_key_handler`, `default_parameter_values` and
  `preference_variable` — the profiles. PSReadLine options,
  `$PSDefaultParameterValues` and the preference variables are session state
  that no file stores, so each owns a marked block of a profile script
  (`# BEGIN config-weave: <name>`) and leaves every other line alone. A
  `BEGIN` with no `END` is an error rather than a truncated profile, CRLF
  files keep CRLF, and a profile Windows PowerShell 5.1 loads gets a UTF-8
  BOM (5.1 reads a BOM-less script as ANSI). With `home` empty, the
  current-user profiles are those of the account config-weave runs as —
  usually SYSTEM or root. `psreadline_option` carries the whole documented
  `Set-PSReadLineOption` surface, each option defaulting to `:unmanaged`,
  `-1` or `""`.
- `repository`, `module`, `module_from_path`, `script_resource`,
  `modules_updated` and `help_updated` — the package-manager shape.
  PowerShell has two generations of these cmdlets, so `provider` defaults to
  `:auto` and prefers PSResourceGet when it can be imported, falling back to
  the PowerShellGet v2 a stock Windows Server ships. `trust_repository` is
  off by default, so an untrusted repository fails rather than being
  trusted silently. `module_from_path` is the manual install: a directory,
  zip or nupkg, local or fetched, copied into the `<Name>/<Version>/` layout
  `Get-Module -ListAvailable` needs, compared by content, and refused when the
  manifest contradicts the version folder. The update windows keep a stamp
  per edition, scope and module set, and `help_updated` fails without
  stamping when every module failed to update.

Module detection uses `Get-Module -ListAvailable` rather than the provider's
own inventory — `Get-InstalledPSResource` and `Get-InstalledModule` only know
about resources those cmdlets installed, so a hand-copied module would read as
missing and be reinstalled on every run — filtered to the scope's own module
directory, the only place install and uninstall act.

A PowerShell that is not installed is a fact (run 1 checks every step before
the install step has applied); a PowerShell that is installed but whose query
fails is an error in every resource and gatherer, never "absent".

### `windows_iis`

Every aspect of an IIS web site, as convergent resources — 70 of them:

- `feature` — the IIS role services, named as symbols (`:web_server`,
  `:asp_net45`, `:windows_auth`, …) rather than raw `Web-*` strings.
- `app_pool` plus `app_pool_recycling` / `_failure` / `_cpu` /
  `_environment_variable` — the pool, its identity and process model, and
  each of its sub-elements as its own resource.
- `site`, `binding`, `application`, `virtual_directory`, `site_limits`,
  `site_logging`, `failed_request_tracing`(`_rule`).
- Security: the four authentication schemes plus the two certificate-mapping
  ones, `authorization_rule`, `ssl_settings`, `ip_restriction`(`_settings`),
  `dynamic_ip_restriction`, `request_filtering`(`_rule`).
- Content and pipeline: `default_document`, `directory_browse`,
  `http_errors`/`http_error`, `http_redirect`, `response_header`, `mime_map`,
  `static_content_cache`, `url_compression`/`http_compression`/
  `compression_scheme`/`compression_mime_type`, `output_cache`(`_profile`),
  `handler`, `handler_access`, `module`, `global_module`, `isapi_filter`,
  `isapi_cgi_restriction`(`_settings`), `fastcgi_application`, `cgi`,
  `websocket`, `server_runtime`, `application_initialization`, `asp`.
- TLS: `certificate`, `self_signed_certificate`, `central_certificate_store`.
- URL Rewrite: `rewrite_module` (installs the separate MSI — or winget or
  Chocolatey), `rewrite_rule`, `rewrite_outbound_rule`,
  `rewrite_pre_condition`, `rewrite_map`(`_entry`),
  `rewrite_allowed_server_variable`.
- Escape hatches: `section_delegation`, `config_property` and
  `config_collection_element` reach whatever the typed resources do not.

Everything is written to `applicationHost.config` under a `<location>` by
default, which is what reaches the `system.webServer/security/*` sections
IIS locks against `web.config`; resources that can legally be delegated take
a `store` param to opt into `web.config` instead. Optional attributes have
**no default** — an omitted param means "leave this setting alone", which is
the only way a bool or int can say so.

Shells out to PowerShell's `WebAdministration` module, so the target needs
the IIS management scripting tools (`feature` with `:scripting_tools`, or
`:web_server` with `include_management_tools = true`).

### `mssql`

Install and configure Microsoft SQL Server on **Windows** (silent `setup.exe`)
and **Linux** (the Microsoft repo plus `mssql-conf`), then converge a broad set
of T-SQL-driven settings via `sqlcmd`:

- `instance` — silent install/uninstall (`ensure = :present|:absent`), feature
  selection, edition, collation, service accounts, TCP and a
  `ConfigurationFile.ini` passthrough on Windows.
- `server_setting` — any `sp_configure` value (compares the running
  `value_in_use`).
- `login`, `database`, `database_user` — principals, databases (recovery
  model, owner, compatibility level) and role membership; `login` and
  `database` drop via `ensure = :absent`.
- `database_cdc`, `cdc_table` — Change Data Capture at the database and table
  level.
- `tcp` — the TCP/IP protocol and static port (registry on Windows, `mssql-conf`
  on Linux), restarting the engine so the change takes effect.
- `replication_distributor`, `replication_publisher` — distributor setup and
  enabling a database for transactional or merge replication.
- `database_mail`, `agent_job` — Database Mail profiles and SQL Agent jobs
  (`agent_job` deletes via `ensure = :absent`).
- `availability_group` — enable Always On HADR and create an availability group
  on the primary (multi-node joins are a scenario concern).
- `instance_info` gatherer — version, edition, collation and HADR state.

Connection parameters (`server`, `instance`, `sql_user`, `sql_password`) are
declared on every T-SQL resource; omit `sql_user` to use integrated (Windows)
authentication. **Known limits:** SQL/SMTP/sa passwords cannot be read back, so
password drift is undetectable (use the `force_password` / `force` flags to
re-apply); database collation is enforced only at create; the Windows install and
availability groups may require a reboot and are covered by the `win_install`
vmlab scenario rather than the container `test`.

## Development

```sh
just ci::check          # the merge bar: everything a change must pass
just validate           # the one part it is made of, run on its own
just test               # everything: container tests, VM tests and scenarios
just test linux_files   # one package
just test mssql:config_converges   # one test
just docs
```

Every test runs in a disposable vmlab instance. A test declaring `image`
provisions a **container** — the OCI image booted in a micro-VM, ready in
seconds; one declaring `template` provisions a full **VM**, which is what
anything needing a real init system, its own kernel, a reboot or a Windows
guest uses. An unfiltered `just test` runs both kinds plus the scenarios, so
it needs vmlab with the `x86_64/alpine-3.23`, `x86_64/debian-13`,
`x86_64/fedora-44`, `x86_64/ubuntu-24.04` and `x86_64/windows-server-2025`
templates. Filter to a package or `package:test` while iterating — the
container tests need no template at all. That is why `just test` sits outside
`ci::check`: it is KVM-bound and slow, so convergence stays a deliberate human
action and the merge bar does not claim to prove it.

A Windows test also needs a Windows build of config-weave to copy into the
guest. config-weave looks for one only in its own build tree, which this repo
does not have. Download `config-weave-windows-x86_64.exe` from a config-weave
GitHub release, or run `just release` in a config-weave checkout and use
`dist/config-weave-windows-x86_64.exe`. Then point the testlab at it:

```sh
export CONFIG_WEAVE_TEST_BINARY_WINDOWS=/path/to/config-weave-windows-x86_64.exe
just test windows_network
```

Without it, a Windows test fails with "no windows test binary was found".

## Package Manager Support

`linux_packages` supports native package managers for the common Linux families and
several opt-in ecosystem managers. Use `manager = "auto"` for native detection, or
set a manager explicitly:

- Debian/Ubuntu: `apt`
- Fedora/RHEL/CentOS/Rocky/Alma/Amazon-style RPM: `dnf5`, `dnf`, `microdnf`, `yum`
- VMware Photon: `tdnf`
- openSUSE/SUSE: `zypper`
- Arch: `pacman`
- Alpine: `apk`
- Void: `xbps`
- Gentoo: `emerge`
- Solus: `eopkg`
- Clear Linux: `swupd`
- Mageia/OpenMandriva: `urpmi`
- Slackware: `slackpkg`
- OpenWrt/embedded Linux: `opkg`
- rpm-ostree systems: `rpm-ostree`
- Optional ecosystem managers: `flatpak`, `snap`, `nix`, `guix`

The test suite avoids network installs. It checks package-state detection on
container images with already-installed base packages and validates every manager
branch through wscript compilation.
