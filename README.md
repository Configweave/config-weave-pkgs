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

### `windows_service`

One `service` resource covers a Windows service's whole SCM registration:
existence (`ensure`), the executable and its `arguments`, `display_name`,
`description`, the account (`user`, `password`, `password_revision`), the
startup type and the running state. Every field is reconciled on an existing
service, not only at creation. An empty string or `:unmanaged` leaves that
field alone, so the resource can stop the Print Spooler without restating its
binary or account.

- The service is matched by its exact name, never by display name or
  wildcard.
- `path` is the bare executable and is always registered quoted, which closes
  the unquoted-service-path hole. Arguments go in `arguments`.
- `user` is compared by SID, so `LocalSystem` and `NT AUTHORITY\SYSTEM`, or
  `.\svc` and `HOST\svc`, are the same account. Any account other than the
  built-in and `NT SERVICE\…` ones is granted `SeServiceLogonRight`, which
  neither `New-Service` nor `Win32_Service.Change` does.
- Passwords reach PowerShell through the environment, never a command line.
  The SCM cannot report a password back, so it is pushed when the service is
  created, when `user` changes, or when `password_revision` changes. Bump
  the revision whenever the password changes.
- `startup` includes `:automatic_delayed`.
- Start, stop and resume wait for the target state, up to `timeout` (60s).
  Pending states are waited out, and a paused service is resumed. A service
  whose `path` or account changed while it should be `:running` is restarted
  so the change takes effect.
- `ensure = :absent` stops the service and waits before deleting it. A
  service that is already marked for deletion and stopped counts as absent,
  because the SCM removes it when its last handle closes.

**Migrating from the old `path`:** `path` used to hold the executable and
its arguments in one unquoted string. Split it:
`path = "C:\\svc\\app.exe"` and `arguments = "-k foo"`. A `path` that does
not exist and contains ` -` or ` /` is rejected with that hint.

### `windows_features`

Three resources, one per Windows mechanism for optional components:

- `windows_optional_feature`: DISM optional features. Enabling also enables
  the features it depends on (`-All`). Disabling leaves those dependencies
  enabled and keeps the payload on disk.
- `windows_capability`: Features on Demand. Adding one usually pulls its
  payload from Windows Update, which can take many minutes. Windows reports
  an unknown capability name as `NotPresent`, so a typo with
  `ensure = :absent` reads as converged.
- `windows_server_feature`: ServerManager roles and features. It needs
  Windows Server; on client Windows, use `windows_optional_feature`.
  `include_management_tools` works in both directions: it installs any
  missing tools, and it removes them with the feature. The tool list is
  whatever ServerManager's `-IncludeManagementTools` adds.

Every name must match exactly one component. Wildcards are rejected, and a
name that matches nothing is an error. The DISM resources take `source` and
`limit_access` for payloads that are not in the component store, such as
`NetFx3` on an offline Server. `windows_server_feature` takes `source`.

A change that needs a reboot to finish reports `reboot_required`. The apply
that made the change reports it, and so does every later check until the
reboot. A pending change is therefore never mistaken for converged, and it
is not redone on every run.

### `windows_installers`

- `msi_package` installs, upgrades or removes an MSI identified by its
  ProductCode. Before msiexec runs, the package's own ProductCode and
  ProductVersion are checked against `product_id` and `version`.
  - When the same ProductCode is installed at another version, the package
    is applied as a minor upgrade (`REINSTALL=ALL REINSTALLMODE=vomus`).
  - A major upgrade changes the ProductCode, so a new major version needs a
    new `product_id`.
  - `alt_product_id` (formerly `package_code`) is a second GUID to look for
    under the Uninstall key. `ensure = :absent` removes whichever GUID it
    finds.
  - Failures quote the error lines from msiexec's verbose log, which is
    kept under `C:\ProgramData\config-weave\installers\logs`.
- `exe_installer` runs an EXE installer. It detects the installation by
  `install_path`, `install_reg` or both. `version` compares `DisplayVersion`
  under `install_reg`, so `version` requires `install_reg`. Removal runs the
  first of these that is set:
  1. `uninstall_path` with `uninstall_args`.
  2. The `QuietUninstallString` or `UninstallString` under the
     `install_reg` key. An `MsiExec /I{…}` entry is made a silent `/X`.
  3. The installer itself, with `uninstall_args`.

  After the installer exits, the resource waits up to two minutes for the
  install markers to appear or disappear, because many uninstallers return
  before they finish.

Both resources take a local path or an `http://` or `https://` URL, plus an
optional `sha256` that is checked before anything runs. Downloaded files
are kept under `C:\ProgramData\config-weave\installers`, one directory per
URL. Windows Installer needs an MSI's original file again for repair and
minor upgrades, so it must not stay in a temp directory.

**Migrating:** rename `package_code` to `alt_product_id`. `exe_installer`
no longer runs `path` with `args` to uninstall. It now uses `uninstall_path`
or the registered uninstall command, or `path` with `uninstall_args`.

### `windows_packages`

Chocolatey, Scoop and winget, one set of resources per manager:

- Chocolatey: `chocolatey_package` (with a `version` hold),
  `chocolatey_source` (URL and `enabled`), `chocolatey_updated` and the
  `chocolatey_packages` gatherer. A package installed at another version is
  moved with `choco upgrade --version --allow-downgrade`, so the hold works
  in both directions. Chocolatey 1.x and 2.x are both supported: 1.x gets
  `--local-only` on every listing.
- Scoop: `scoop_package` (accepts `bucket/app`), `scoop_bucket` (compares
  the clone's origin with `url`), `scoop_cache_updated` and the
  `scoop_packages` gatherer. Scoop is per-user, so everything happens under
  the scoop root (`SCOOP`, else `~\scoop`) of the account config-weave runs
  as. The refresh stamp is kept there too. For SYSTEM that root is under
  `System32`, where scoop's shim executables cannot start, so the resources
  put scoop's own git first on `PATH` (every bucket operation needs git).
  Apps installed for SYSTEM still have broken shims, so prefer Chocolatey
  or winget there.
- winget: `winget_package` (with a `version` hold), `winget_source` (URL
  and `type`), `winget_cache_updated` and the `winget_packages` gatherer.
  Detection uses the `Microsoft.WinGet.Client` module if it is installed,
  else `winget export`. The `winget list` table is never parsed, because
  its headers are localized and its columns are truncated. When winget is
  not on `PATH` (it never is for SYSTEM), the newest App Installer copy
  under `WindowsApps` is used. That copy starts for SYSTEM only after the
  Visual C++ 2015-2022 x64 runtime is installed machine-wide.

Every source and bucket resource takes `ensure`. Names compare
case-insensitively, as the managers compare them. Every script forces UTF-8
output, so a non-ASCII package name cannot blank a listing. Chocolatey and
Scoop are found on `PATH` first and then in their default locations, so a
manager installed earlier in the same run is usable at once. A missing
manager makes a removal converged, makes a gatherer return the empty shape,
and makes an install fail with a clear error.

`concurrency = "exclusive"` serialises steps of one resource type only. Two
steps for the same manager but of different types, such as a source and a
package, can run at once. Chain them with `requires` when one depends on
the other.

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
