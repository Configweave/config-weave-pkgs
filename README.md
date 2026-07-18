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

## Packages

Removal is expressed with `ensure = "absent"` on the same resource that
creates the thing — every install/remove resource takes an `ensure` param
(`"present"`, the default, or `"absent"`) instead of a separate `*_absent`
resource.

- `linux_facts`: Linux OS, init system, services, mounts and network facts.
- `linux_files`: files (exact content or URL-fetched), directories,
  symlinks/hard links, archives and modes.
- `linux_packages`: package-manager resources for common Linux distributions,
  plus the package-manager detection gatherer.
- `linux_services`: service state, service enablement and systemd unit files.
- `linux_accounts`: users, groups, SSH authorized keys and per-user sudo rules.
- `linux_system`: sysctl, hostname, timezone, locale, cron, logrotate and fstab.
- `linux_network`: hosts entries, SSH config snippets and firewall front-ends.
- `linux_kde`: KDE Plasma 6 configuration files, themes and autostart entries.
- `linux_tmux`: tmux configuration, options, key bindings, plugins and session files.
- `linux_python`: pip packages, system-wide or in a virtualenv.
- `linux_scm`: git and subversion checkouts.

Windows packages (`windows_installers`, `windows_packages`, `windows_features`,
`windows_registry`, `windows_updates`, `windows_domain`) and the cross-platform
`mssql` package round out the library.

### `mssql`

Install and configure Microsoft SQL Server on **Windows** (silent `setup.exe`)
and **Linux** (the Microsoft repo plus `mssql-conf`), then converge a broad set
of T-SQL-driven settings via `sqlcmd`:

- `instance` — silent install/uninstall (`ensure = present|absent`), feature
  selection, edition, collation, service accounts, TCP and a
  `ConfigurationFile.ini` passthrough on Windows.
- `server_setting` — any `sp_configure` value (compares the running
  `value_in_use`).
- `login`, `database`, `database_user` — principals, databases (recovery
  model, owner, compatibility level) and role membership; `login` and
  `database` drop via `ensure = "absent"`.
- `database_cdc`, `cdc_table` — Change Data Capture at the database and table
  level.
- `tcp` — the TCP/IP protocol and static port (registry on Windows, `mssql-conf`
  on Linux), restarting the engine so the change takes effect.
- `replication_distributor`, `replication_publisher` — distributor setup and
  enabling a database for transactional or merge replication.
- `database_mail`, `agent_job` — Database Mail profiles and SQL Agent jobs
  (`agent_job` deletes via `ensure = "absent"`).
- `availability_group` — enable Always On HADR and create an availability group
  on the primary (multi-node joins are a scenario concern).
- `instance_info` gatherer — version, edition, collation and HADR state.

Connection parameters (`server`, `instance`, `sql_user`, `sql_password`) are
declared on every T-SQL resource; omit `sql_user` to use integrated (Windows)
authentication. **Known limits:** SQL/SMTP/sa passwords cannot be read back, so
password drift is undetectable (use the `force_password` / `force` flags to
re-apply); database collation is enforced only at create; the Windows install and
availability groups may require a reboot and are covered by the `win_install`
vmlab scenario rather than the docker `test`.

## Development

```sh
just validate
just test               # everything: docker tests, vmlab tests and scenarios
just test linux_files   # one package
just test mssql:config_converges   # one test
just docs
```

An unfiltered `just test` runs every test on its declared backend plus the
scenarios, so it needs Docker (or Podman) **and** vmlab with the
`x86_64/windows-server-2025` and `x86_64/ubuntu-24.04` templates. Filter to a
package or `package:test` while iterating — the docker-only tests need no
vmlab.

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
branch through Wisp compilation.
