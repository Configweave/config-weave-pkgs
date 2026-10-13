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

### `linux_accounts`

Local users, groups and per-user sudo rules. 3 resources:

- `user` — `uid`, primary `group` (name or gid), `home` and `shell`, each
  compared only when set and reconciled on an existing user with one
  `usermod`. A new `home` is moved there with `usermod -m`, unless the
  directory already exists: then it is adopted as it is and the old home is
  left in place. `system` only applies at creation; an existing account on
  the wrong side of `UID_MIN` is an error unless `uid` is set. `:absent`
  takes `remove_home` (`userdel -r`).
- `group` — `gid` is reconciled with `groupmod -g`, which does not re-own
  files carrying the old gid. `:absent` fails while the group is still a
  user's primary group, so remove the user first with `requires`.
- `sudoers_user` — one rule, `<user> ALL=(ALL:ALL) [NOPASSWD: ]<commands>`,
  in `/etc/sudoers.d/<user>`, owned by root with mode 0440. A dotted user
  (`john.doe`) gets `john_doe`, since sudo skips file names with a dot.
  The rule is checked with `visudo -cf` under a name sudo ignores and only
  then renamed into place, so an invalid rule never goes live. `user` may be
  `%group`.

Only `/etc/passwd` and `/etc/group` are read: an LDAP or SSSD account of the
same name is not treated as local. Names are letters, digits, `_`, `.` and
`-`, not starting with `-` or `.`; `home` and `shell` are absolute paths;
`commands` is one non-empty line.

### `linux_ssh`

Keys, known hosts and ssh/sshd configuration. 4 resources:

- `authorized_key` — one key in a user's `~/.ssh/authorized_keys`. Lines
  match on key type and blob, so a line for the same key with other options
  or another comment is rewritten (`:present`) or removed (`:absent`). check
  also requires what sshd's StrictModes requires: `.ssh` 700 and the file
  600, both owned by the user.
- `known_host` — one `known_hosts` entry, with `ensure`. `name` makes the
  step own a host: a new key of the same type replaces the old one, and
  `:absent` with only `name` removes every plain entry for that host. The
  default file is in the passwd home of the user config-weave runs as, not
  `$HOME`. In a home, `.ssh` and the file belong to the home's owner.
- `ssh_config_setting` — one `/etc/ssh/ssh_config.d` drop-in per key and
  `host` pattern.
- `sshd_config_setting` — one `/etc/ssh/sshd_config.d` drop-in per key. When
  sshd is installed, apply runs `sshd -t` and puts the old drop-in back if
  sshd rejects the new one. check compares the effective value from
  `sshd -T`, so a key set earlier by another file is an error, not a false
  converge. `reload = true` reloads a running sshd; otherwise the running
  daemon keeps its old settings until it is restarted.

Drop-ins are named `10-config-weave-…` so they sort ahead of
`50-cloud-init.conf` and other distribution drop-ins: ssh and sshd keep the
first value they read. Files left by older versions under the
`50-config-weave-…` name are removed when the step next applies. Both
drop-in resources need the distribution's `Include …/*.d/*.conf` line in
the main config, which Debian, Ubuntu and Fedora ship. Option keys are
letters and digits only, and line breaks in any value are rejected.

### `linux_network`

Hosts entries and firewall rules. 6 resources:

- `hosts_entry` — exactly one `/etc/hosts` line for an address, mapping it
  to exactly the given names in order. Lines match on their first field, so
  spacing and trailing comments do not matter; a line with old names is
  rewritten in place and extra lines for the address are dropped.
  `:absent` removes every line for the address. The file is rewritten in
  place because container runtimes bind-mount it.
- `firewalld_rule` — one service, port, source or rich rule in a zone.
  firewalld must be running (`firewall-cmd` needs the daemon even for
  `--permanent`). `permanent = true`, the default, manages both the running
  firewall and the saved configuration; `false` manages the running
  firewall only, which a reload resets.
- `ufw_rule` — a ufw rule for a port spec (`22/tcp`, `6000:6007/tcp`) or an
  application profile (`OpenSSH`, `WWW Full`), optionally from a source.
  `action` is `:allow`, `:deny`, `:reject` or `:limit`. Presence is read
  from `ufw show added`, so it works while ufw is inactive; enabling ufw is
  not managed.
- `nftables_table`, `nftables_chain`, `nftables_rule` — the running nftables
  ruleset; nothing is saved to `/etc/nftables.conf`. `family`, `type`,
  `hook` and `policy` are symbols. A chain is compared on its type, hook,
  priority and policy (from `nft -j`): a policy change is made in place,
  and any other change recreates the chain, which drops its rules, so rule
  steps for the chain should `require` the chain step. Rules compare as
  text, ignoring whitespace and counter and quota state, so write them as
  `nft list chain` prints them. When nft stores a rule in another form
  (`tcp dport ssh` becomes `tcp dport 22`), apply removes the copy it added
  and fails, naming the form to use.

### `linux_kde`

KDE Plasma configuration files, edited directly with no KDE tools needed.
1 resource and 2 gatherers:

- `kconfig_entry` — one key in a file under `~/.config`, in `[group]` or
  `[group][subgroup]`. Keys match the way KConfig reads them (split at the
  first `=`, whitespace trimmed), values are escaped the way `kwriteconfig6`
  writes them, and a duplicate key is removed. `value` is required when
  `:present`; `""` writes an empty value. Files and directories it creates
  belong to the owner of `home`, and `home` must already exist. Steps run
  exclusively, so several steps can edit one file.
- `kde_paths` — the home, `~/.config` and `~/.local/share` paths, and
  whether `kreadconfig6`, `kwriteconfig6` and `plasma-apply-colorscheme` are
  on `PATH`.
- `kde_version` — `plasma_major` from `plasmashell --version`, and the
  KConfig tool generation on `PATH` (`kconfig_tools_major`,
  `has_legacy_kconfig_tools` when only the 5 tools exist).

Without `home`, both use the passwd home of the account config-weave runs
as. A running Plasma session can write its own settings back over an edit:
apply while the user is logged out, or reload the component afterwards (for
example `qdbus org.kde.KWin /KWin reconfigure`) or log in again.

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
