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
- `linux_apt` / `linux_dnf` / `linux_pacman` / `linux_apk` / `linux_zypper`:
  one package per package manager — install, cache refresh and, where the
  manager supports them, repositories, keys and holds (`linux_pacman` also
  installs AUR packages via yay/paru).
- `linux_flatpak`: Flatpak apps, runtimes and remotes per installation, and
  `updated`, which upgrades every installed app rather than refreshing a
  cache. See [Package managers](#package-managers).
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

### `windows_powershell`

PowerShell itself, as convergent resources — installing it, and every setting
it reads. 26 resources and 6 gatherers:

- `pwsh_installed` — install or remove PowerShell 7 by `:msi`, `:winget` or
  `:zip` on Windows and `:repo` or `:tarball` on Linux. The archive methods
  own a versioned `install_root` of their own, which is what makes them the
  only side-by-side-capable ones; the MSI method carries the documented
  properties (`add_path`, `enable_remoting`, `register_manifest`, the two
  context-menu items, Microsoft Update) and reports `RebootRequired` on
  msiexec 3010.
- `psremoting` and `session_configuration` — the WinRM endpoints. Which
  endpoint `Enable-PSRemoting` registers depends on the PowerShell that runs
  it, so `edition` is what picks between `microsoft.powershell` and
  `PowerShell.7` rather than a name the caller has to know.
- `config_setting`, `module_path`, `experimental_feature`, `win_compat` and
  `log_setting` — `powershell.config.json`. `config_setting` is the generic
  escape hatch: a dotted key path, or `literal_key` for a module-qualified
  key such as `Microsoft.PowerShell:ExecutionPolicy`. All take a `path`
  override, which is what lets them run on a machine with no PowerShell 7
  installed at all.
- `execution_policy`, `script_block_logging`, `module_logging`,
  `transcription`, `protected_event_logging` and
  `console_session_configuration` — the registry behind `Set-ExecutionPolicy`
  and the PowerShell Group Policy settings, driven through the `registry`
  host module. `edition` picks the policy key: Windows PowerShell 5.1 reads
  `…\Policies\Microsoft\Windows\PowerShell`, PowerShell 7 reads
  `…\Policies\Microsoft\PowerShellCore`.
- `profile`, `profile_snippet`, `psreadline_option`,
  `psreadline_key_handler`, `default_parameter_values` and
  `preference_variable` — the profiles. PSReadLine options,
  `$PSDefaultParameterValues` and the preference variables are session state
  that no file stores, so each owns a marked block of a profile script
  (`# BEGIN config-weave: <name>`) and leaves every other line alone.
  `psreadline_option` carries the whole documented `Set-PSReadLineOption`
  surface, each option defaulting to `:unmanaged`, `-1` or `""`.
- `repository`, `module`, `module_from_path`, `script_resource`,
  `modules_updated` and `help_updated` — the package-manager shape.
  PowerShell has two generations of these cmdlets, so `provider` defaults to
  `:auto` and prefers PSResourceGet when it can be imported, falling back to
  the PowerShellGet v2 a stock Windows Server ships. `module_from_path` is
  the manual install: a directory, zip or nupkg, local or fetched, copied
  into the `<Name>/<Version>/` layout `Get-Module -ListAvailable` needs.

Detection deliberately uses `Get-Module -ListAvailable` rather than the
provider's own inventory: `Get-InstalledPSResource` and `Get-InstalledModule`
only know about resources those cmdlets installed, so an in-box or
hand-copied module would read as missing and be reinstalled on every run.

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

## Package managers

### `linux_packages`

`linux_packages` has one gatherer, `package_manager`. It returns `manager`, a
symbol naming the host's package manager, and `known`, false when nothing was
found. Use it to choose between the per-manager packages: `linux_apt`,
`linux_dnf`, `linux_zypper`, `linux_pacman`, `linux_apk` and `linux_flatpak`.
It manages nothing itself.

Detection checks the files each manager installs and takes the first match,
in this order:

1. `:rpm_ostree`, when `/run/ostree-booted` exists. Fedora Atomic and CoreOS
   ship dnf5 too, so this comes before the dnf family.
2. The system managers: `:apt`, `:dnf5`, `:dnf`, `:microdnf`, `:yum`,
   `:tdnf`, `:zypper`, `:pacman`, `:apk`, `:xbps`, `:emerge`, `:eopkg`,
   `:swupd`, `:urpmi`, `:slackpkg`, `:opkg`.
3. The ecosystem managers, only when no system manager was found: `:flatpak`,
   `:snap`, then `:nix` (`/nix/store` and a `nix-env` in a profile) and `:guix`
   (`/gnu/store` and a `guix` in a profile).
4. `:unknown`.

A Debian host with flatpak installed is `:apt`. Several symbols (`:snap`,
`:nix`, `:xbps` and others) have no package in this library behind them.

### `linux_apk`

- `package` matches `name` exactly against `/etc/apk/world`, so a pin or
  constraint (`tree=2.1.1-r0`, `xz>=5`) or a tag (`tree@testing`) is
  compared as written, and a package installed only as a dependency is added
  to world. `:absent` fails, with apk's output, when other installed
  packages need the package, unless `remove_dependents = true` (`apk del -r`).
- `cache_updated` runs `apk update` when its own stamp is older than
  `max_age`, or when `/etc/apk/repositories`, `repositories.d` or `keys`
  changed since.
- `repository` manages one whole line of `/etc/apk/repositories`, including
  any `@tag`; commented lines do not count.
- `signing_key` writes `/etc/apk/keys/<name>.rsa.pub` from `content`, or from
  a `url` checked against `sha256`.

Every apk call waits up to five minutes for apk's database lock.

### `linux_pacman`

- `package` accepts a package, a name an installed package provides, or a
  group. It installs with `pacman -S --needed` and never syncs, so run
  `cache_updated` first. `:absent` fails when other packages depend on the
  package.
- `cache_updated` runs `pacman -Sy` when its stamp is older than `max_age`,
  or when `pacman.conf` or `pacman.d` changed since.
- `aur_package` builds with yay or paru (`helper = :auto`, `:yay`, `:paru`)
  as `user`, through `sudo -H` from that user's home. The helper must be on
  the user's PATH, and the user needs passwordless sudo. Removal is plain
  `pacman -R` and needs neither. `aur_cache_updated` is the helper's `-Sy`:
  neither helper caches AUR metadata.
- `repository` owns a `[name]` section of `pacman.conf`: `servers` and
  `siglevel`.
- `key` adds a key from `content` or a keyserver and locally signs it. It
  needs an initialised keyring (`pacman-key --init`).
- `hold` manages `IgnorePkg` entries in `[options]`.

pacman has no lock wait, so every pacman call first waits up to five minutes
for `db.lck` to go.

### `linux_flatpak`

Every resource works on one installation: `installation = :system` (the
default) or `:user`, which is root's, since config-weave runs as root.

- `package` installs an app (`kind = :app`) or a runtime (`kind = :runtime`)
  from `remote`. It also checks which remote the installed copy came from,
  and reinstalls from `remote` when it differs.
- `remote` adds the remote, re-enables a disabled one (Fedora ships flathub
  disabled), and reconciles `url` and `gpg_verify`. A `.flatpakrepo`
  descriptor URL is only read when the remote is added. `:absent` fails
  while anything installed came from the remote.
- `updated` runs `flatpak update`, which upgrades every installed app and
  runtime in the installation. This is not a metadata refresh: running apps
  keep their old version until restarted.

### Ordering

apk and pacman wait for their own locks, but steps of different resource
types in one package can still run at the same time. Order them with
`requires`, for example a repository and its key before `cache_updated`, and
`cache_updated` before `package`.
