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

### `windows_registry`

Registry values and keys:

- `value` — a value with its kind and data, or `ensure = :absent`. Every
  kind Windows programs commonly write is covered: `:sz`, `:expand_sz`,
  `:dword`, `:qword`, `:multi_sz` (strings in `data_list`) and `:binary` (hex
  text in `data`, or byte ints in `data_list`). The kind is compared as well
  as the data, so a `REG_SZ` where `:expand_sz` is wanted is drift. Numbers
  are decimal, and a negative number is the signed spelling of the same bits
  (`"-1"` is `0xFFFFFFFF` as a DWORD). `name = ""` or `"(Default)"` is the
  key's default value.
- `key` — a key, optionally with an `owner` and explicit Allow rules in
  `permissions`, or `ensure = :absent`, which deletes the whole subtree.
  Accounts are compared as SIDs and rights as bit masks, so the composite
  rules Windows merges (`ReadKey, WriteKey`) still match. The default
  `permissions_mode = :additive` only adds rules. `:exact` also removes
  explicit rules that are not listed. `:absent` refuses hive roots,
  anything one level below a hive (`HKLM\Software`, `HKCU\Software`), and
  well-known system keys.

Both resources take any hive spelling (`HKLM`, `hklm`, `HKEY_LOCAL_MACHINE`)
and a `view`. `:native` is the 64-bit registry the agent sees, with no
`WOW6432Node` redirection. `:wow64_32` is what a 32-bit program sees.
`HKCU` is the hive of the account the agent runs as, which under the usual
SYSTEM service is SYSTEM's own hive. To reach a particular user, write to
`HKU\<sid>`.

The work goes through .NET's `RegistryKey` in Windows PowerShell rather than
the host `registry` module, because that module cannot report a value's kind,
read binary values, or choose a view.

### `windows_files`

Files, directories, links and NTFS permissions, the Windows counterpart of
`linux_files`:

- `file` — exact `content`, or a `url` download checked against `sha256`.
  `template` renders a Tera template. Both take `line_endings` (`:preserve`,
  `:crlf`, `:lf`). Text is written as UTF-8 without a BOM, in place, so the
  file keeps its own permissions. A file that is not valid UTF-8 (UTF-16
  from Notepad or Windows PowerShell's `Out-File`) is drift and is
  rewritten.
- `directory` — a directory and its parents, or a recursive delete. The
  delete refuses drive and share roots, `Windows`, `Program Files`,
  `ProgramData`, `Users` and user profile roots, the directories the
  environment names, and links.
- `symlink` — a symbolic link (`kind = :symbolic`) or a junction
  (`:junction`), or `ensure = :absent`. Dangling links are handled. A real
  file or directory at the link's path is never replaced.
- `permissions` — `owner`, Allow rules in `acl`, Deny rules in `deny`, and
  `inheritance`. Accounts are compared as SIDs, so unqualified and localised
  names work, and rights are compared as bit masks over the explicit rules.
  On a directory, a rule counts only when it reaches the folder, its
  subfolders and its files. `acl_mode = :exact` removes the explicit rules
  that are not listed. With `inheritance = false`, the inherited rules are
  copied by default (`inherited_rules = :copy`). `:remove` drops them
  instead, and can lock out SYSTEM and Administrators. The owner and the
  DACL are written separately, so a path owned by TrustedInstaller can still
  have its rules changed.
- `path_info` and `paths_matching` gatherers — a path's type, size,
  attributes, owner, link target and optional SHA-256, and a wildcard
  listing.

### `windows_share`

`share` manages an SMB share: its `path`, `description`, `encrypt_data`,
`caching_mode`, `folder_enumeration_mode`, `concurrent_user_limit`, and its
access list in `full_access`, `change_access` and `read_access`. The three
lists together are the share's whole access list. A grant to any other
account is revoked and Deny entries are removed. Accounts are matched by
SID. With all three lists empty, access is left unmanaged.

An existing share is reconciled in place, so open sessions and unmanaged
settings survive. Only a changed `path` recreates the share, and that
happens after every account has been resolved and the directory has been
created. `ensure = :absent` removes the share and leaves its directory. It
refuses administrative shares such as `ADMIN$`.

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
