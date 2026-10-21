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

### Version ranges

A `version` param that says which version of Windows software must be
installed takes a version range in the npm (node-semver) syntax, matched by
config-weave's [`version` module](https://github.com/Configweave/config-weave/blob/main/docs/manual/pages/reference/mod-version.wcl).
This covers `windows_installers.msi_package` and `exe_installer`,
`windows_packages.winget_package` and `chocolatey_package`,
`windows_powershell.pwsh_installed`, `vsix.extension` and
`mssql.reporting_services`.

| Range | Matches |
|---|---|
| `1.2.3`, `15.0.4490.9` | exactly that version (three or more parts); missing parts are 0 |
| `7`, `7.4`, `7.x`, `20.2.*` | any version with that prefix: `7.4` is any 7.4.x |
| `>=14.38`, `>1.2`, `<2`, `<=1.4.7` | comparisons |
| `>=14.38 <15` | both (space-separated AND) |
| `^7.5.0`, `~20.2.1` | same major (`<8`), same minor (`<20.3`) |
| `1.2.3 - 2.3.4` | inclusive range |
| `^6 \|\| ^7` | either |
| empty or `*` | any installed version |

Versions compare part by part as integers with any number of parts
(`14.9 < 14.38`), a leading `v` is accepted (`v14.38.33130.00`), and a
pre-release such as `7.6.0-preview.3` matches only a range that names a
pre-release. An installed version spelled exactly like the param always
matches. `check` reports the step converged when the installed version
satisfies the range; an installed version that is not a version at all is
an error naming where it was read. When the range is not one exact version,
the resources that install from a feed (`winget_package`,
`chocolatey_package`, `pwsh_installed`, Marketplace `vsix.extension`)
install the newest version the feed offers that satisfies it, and an error
lists the newest available when none does; the installer resources
(`msi_package`, `exe_installer`, `reporting_services`, a `vsix` file) run
what `path` or `setup_path` names, and the re-check after `apply` fails the
step if it left a version outside the range.

**Migrating:** a one- or two-part pin is now a prefix, so `version = "7.4"`
accepts any 7.4.x build, where it used to match only 7.4 itself (or
7.4.0). Write `7.4.0` to keep an exact pin.

The Linux package managers (`linux_apt`, `linux_dnf`, `linux_zypper`) keep
`version` an exact pin, because distro versions follow their own ordering
rules (epochs, `~`, `-release`); a value that reads as a range is an error.

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
`windows_storage`,
`windows_defender`, `windows_iis`, `windows_powershell`) and the
cross-platform `mssql` package round out the library.
`visual_studio` installs Visual Studio itself and `vsix` installs
extensions into Visual Studio and VS Code.

### `linux_files`

Files, directories, links, archives and modes. 6 resources and 2 gatherers:

- `file` — exact `content`, or fetched from `url`. Writes go to a temp file
  beside the target and are renamed into place, keeping the old file's owner
  and mode unless `mode`/`owner`/`group` say otherwise. A download is
  verified against `size` and `sha256` before it replaces anything, and a
  failed or short download is retried (`retries`, default 3), so an
  interrupted run never leaves a file that `check` accepts. `size` is
  checked first and costs nothing, so a large file with only `size` set is
  never hashed. Without either, a url is fetched once and never re-checked,
  so set one whenever the content matters. With no `mode`, `owner` or
  `group`, `check` runs no shell command.
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
### `linux_systemd`, `linux_openrc`, `linux_runit` and `linux_sysvinit`

One package per init system, each with a `service` resource of the same
shape: `name`, `ensure`, a body (`unit`, `script` or `run`) that is written
only when set, and `state` and `enabled`, both defaulting to `:unmanaged`.
The four behave the same way where their init systems allow it:

- `name` is a plain name. A `/`, whitespace, glob characters, or a leading
  `.` or `-` is an error in both check and apply.
- A missing exec bit on the script is drift and is restored with
  `chmod a+x` (OpenRC, runit and SysV).
- When the body changes and `state = :running`, a running service is
  restarted. systemd, OpenRC and runit also detect a service still running
  from an older file (the file is newer than the service's last start) and
  restart it. SysV has no start time to compare against, so it restarts
  only on the run that rewrote the script.
- `ensure = :absent` stops the service first, removes every trace of its
  enablement, and deletes the file. `state` and `enabled` are ignored.

Differences:

- `linux_systemd` needs systemd running as PID 1. Enablement is the unit
  file state `systemctl is-enabled` prints. Static, indirect, masked and
  transient units already satisfy `:disabled`. Enabling a static unit, or
  disabling a generated or alias unit, is an error. `name` may end in
  `.service`. `:absent` deletes only the `/etc/systemd/system` copy: a
  vendor unit under `/usr/lib` is stopped and disabled but stays.
  `unit_file` writes any unit type or drop-in (`foo.service.d/x.conf`),
  takes `ensure`, and skips `daemon_reload` when systemd is not running.
- `linux_openrc` reads `rc-service status` exit codes. A crashed service
  (32) is zapped, then started for `:running` or left stopped for
  `:stopped`. `enabled` manages one `runlevel` (default `default`).
  `:absent` removes the service from every runlevel.
- `linux_runit` links `sv_dir/<name>` into `service_dir`. A wrong link is
  replaced, and a real directory at the link path is an error. `:stopped`
  and `:running` also manage a `down` file, so the state holds across runsv
  restarts and reboots. `:running` needs the service linked. On an unlinked
  service, `:stopped` means the down file alone. `:absent` waits for runsv
  to exit before it deletes the definition.
- `linux_sysvinit` uses update-rc.d (Debian) or chkconfig (RHEL family).
  `:disabled` turns start links into kill links. `:enabled` errors when the
  script's LSB `Default-Start` is empty. `:absent` removes start and kill
  links, even when the script is already gone.
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
### `git`

Global and system git configuration. Every resource shells out to
`git config`, so git must be installed on the target; `home` needs
git 2.30 or later.

- Section resources (`user`, `core`, `init`, `commit`, `push`, `pull`,
  `fetch`, `merge`, `rebase`, `diff`, `status`, `log`, `color`) declare one
  param per config variable, with no defaults. An omitted param, or an
  empty string, leaves that key alone, so these resources cannot remove a
  key. A key is converged when it holds exactly one value equal to the
  desired one. Bool and int params are compared the way git reads them
  (`yes`, `on`, `1` and a bare `key` line all count as `true`; `1k` counts
  as `1024`). String and symbol params fold only `yes`/`on`/`no`/`off`,
  never digits, because keys such as `merge.log` treat `1` as a count.
- `alias`, `safe_directory` and `config_entry` take `ensure`.
  `config_entry` reaches any variable the typed resources do not, and is
  the way to remove a key. With `ensure = :absent` and a `value`, it
  removes only that occurrence of a multi-valued key. A malformed key is an
  error, not a no-op. Values are compared exactly, folding only the
  true/false word spellings, and are never logged; git takes them only on
  its command line, so a secret such as an `http.extraHeader` token is
  briefly visible in the process list while git runs.
- `scope` is `:global` (the default) or `:system`. `home` points global
  scope at `<home>/.gitconfig` and is ignored under `:system`.

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
  on msiexec 3010. `version` is a [version range](#version-ranges): an
  exact release installs directly, and any other range installs the newest
  release inside it, listed from the release tags of PowerShell's git
  repository (`~7.4` is the newest 7.4 patch); the archive methods then need
  an explicit `install_root`. `version = "latest"` tracks the channel's current
  release, read from PowerShell's `tools/metadata.json` on
  raw.githubusercontent.com (or `latest_url`) by check and apply alike: an older build is drift, and a
  failed lookup is an error that names the URL. The archive methods need an
  explicit `install_root` with `"latest"`. `:winget` runs the newest
  `winget.exe` under `WindowsApps`, so it works as SYSTEM, and asks for the
  MSI installer at machine scope so the build lands in the MSI's root.
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

Behaviour worth knowing before writing a playbook:

- **Existing objects are reconciled, not just created.** Every attribute a
  step names is compared and set in place on an object that already exists.
  Collection entries (handlers, rewrite rules, tracing rules) keep their
  position, since IIS evaluates them in order. The few exceptions are named
  in the param docs: `certificate.exportable` is applied at import only, and
  `self_signed_certificate.valid_days` sets the lifetime of a new
  certificate, while `renew_before` decides when an existing one is
  replaced.
- **Names are matched the way IIS matches them** — case-insensitively — and
  looked up exactly. A site or pool name is never a wildcard pattern, and a
  collection key that differs only in case updates the existing entry.
- **Removal is `ensure = :absent`** everywhere, including
  `config_property`, which deletes an attribute at one level so the
  inherited value applies again. Removing an https `binding` (or the
  `site` that owns it) also deletes its HTTP.sys certificate binding unless
  another https binding uses the same endpoint. `global_module` refuses
  to unregister a module that a `<modules>` entry still names, and
  `application` refuses to remove a site's root application.
- **Secrets stay off the command line.** Passwords (app pool,
  anonymous authentication, virtual directory, PFX import, central
  certificate store) reach PowerShell through the environment and are
  masked in the log. Write-only passwords are compared where IIS hands them
  back decrypted; the central certificate store keeps a salted hash of what
  it last wrote.
- **Certificates.** `binding` checks both the configured certificate hash
  and the HTTP.sys binding. `self_signed_certificate` only ever matches
  self-signed certificates (issuer equal to subject) and, when it replaces
  one — renewal, or changed `dns_names` or `key_length` — moves every https
  binding on the old thumbprint to the new certificate before deleting the
  old one. `certificate` refuses to remove by subject when more than one
  certificate matches, and checks a `sha256` when given.
- **URL Rewrite conditions** are `"input|pattern"` strings with an optional
  last field of flags: `"{REQUEST_FILENAME}||isFile,negate"`. The pattern
  runs to the flags field, so a regex alternation keeps its `|`.
  `rewrite_rule.server_variables` takes `"NAME|value"` strings; each name
  must be allowed with `rewrite_allowed_server_variable` first.
  `rewrite_module` installs only an MSI that matches `sha256` or carries a
  valid Microsoft signature, and refuses plain http without `sha256`.

Shells out to PowerShell's `WebAdministration` module, so the target needs
the IIS management scripting tools: `feature` with `:scripting_tools`
(`include_management_tools = true` on `:web_server` brings only IIS
Manager). The shared script
code lives in the package's `lib/`: `common.ws` (helpers and the PowerShell
prelude), `section.ws` and `collection.ws` (the read-compare-write behind
most resources) and `rewrite.ws`.

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

Values and keys go through the host `registry` module. Only a key's owner
and permissions go through .NET's `RegistryKey` in Windows PowerShell,
because the host has no ACL API.

### `windows_files`

Files, directories, links and NTFS permissions, the Windows counterpart of
`linux_files`:

- `file` — exact `content`, or a `url` download kept at `path`: it goes to
  `<path>.config-weave-download`, is checked against `size` and `sha256`,
  retried when it fails or comes up short (`retries`, default 3), and only
  then renamed into place (or swapped in with `ReplaceFile` over an existing
  file, which keeps its NTFS permissions). An interrupted download never
  leaves a file that `check` accepts, and `size` alone checks a
  multi-gigabyte ISO without hashing it on every run. `template` renders a
  Tera template. Both take `line_endings` (`:preserve`,
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
- `iso_mount` — mounts an ISO (`Mount-DiskImage`) at an optional
  `drive_letter`, moving a mount at another letter there; `ensure = :absent`
  dismounts it. A mount does not survive a reboot, which the next run
  reports as drift.
- `iso_extract` — copies an ISO's contents to `destination` with
  `robocopy /MIR`, clearing the read-only flag optical media carries, then
  writes `<destination>\.config-weave-iso` recording the image's path, size
  and modification time. A copy that stopped part way, or a different image,
  is drift. An image it mounted itself is always dismounted; one that was
  already mounted is left alone. `destination` is mirrored, so the
  directory `:absent` refuses to delete are refused here too.
- `xml_value` — sets one element's text or an attribute (`xpath`, `value`,
  `attribute`, `namespaces`), creates missing elements with `create = true`,
  changes every match with `all = true`, or removes nodes with
  `ensure = :absent`. The file keeps its encoding, BOM, line endings,
  comments and declaration, and is swapped in with `ReplaceFile`.
  `restart_service` restarts a running service only when the file changed;
  a restart that fails is retried by the next run.

### `windows_storage`

- `volume` — brings a data disk into use: online and writable, initialised
  (`partition_style`, `:gpt` or `:mbr`), one partition of the whole disk at
  `drive_letter`, formatted `:ntfs` or `:refs` with `label` and
  `allocation_unit_size`. `disk` selects it: `"raw"` for the only blank
  disk, a disk number, or a serial number or UniqueId (stable across
  reboots; vmlab and VHD disks have only a UniqueId). A changed label is
  fixed in place, and a selected disk whose only volume matches is moved
  back to `drive_letter`.

The safety rules are fixed: the boot and system disks are never touched,
`disk = "raw"` fails unless exactly one blank disk is attached, and a disk
that is not blank is only wiped with `allow_reformat = true`. That covers a
changed file system, cluster size or partition style, and `ensure = :absent`,
which clears the disk back to RAW.

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
### `windows_updates`

Windows Update itself, and the Group Policy values that steer it. 4 resources:

- `updated` — the package-manager shape. `check` reports `reboot_required`
  while an installed update waits for a restart, skips the search while the
  last fully drained run for the same `query` and `source` is younger than
  `max_age`, and otherwise searches. `apply` installs through a one-shot
  scheduled task running as SYSTEM, because the Windows Update Agent refuses
  downloads and installs to network logon sessions (SSH, WinRM). It accepts
  EULAs, skips updates that would ask for user input, loops up to five passes
  as later updates become applicable, and logs each update's result code and
  HRESULT. It returns `reboot_required` when an install needs a restart, so a
  playbook loops apply, reboot, apply until nothing is pending. The default
  `query` is `IsInstalled=0 and IsHidden=0 and Type='Software'` (no drivers);
  `source` picks `:default` (WSUS when policy names one),
  `:windows_update` or `:microsoft_update`. There is no timeout.
- `policy` — the Configure Automatic Updates values (`NoAutoUpdate`,
  `AUOptions` including option 7, the install schedule, reboot behaviour,
  detection frequency).
- `wsus` — the WSUS server, status server, target group and `UseWUServer`.
- `deferral` — Windows Update for Business deferrals, release channel
  (`BranchReadinessLevel`) and active hours (at most 18 hours). Microsoft
  documents these for client editions; Windows Server takes no feature
  updates through Windows Update.

Every enumerated policy param has an `:unmanaged` member and every numeric
one takes `-1`. A managed value missing from the registry is drift, so a
wanted `0` is written. `ensure = :absent` on `policy`, `wsus` or `deferral`
deletes every value that resource manages, returning it to "Not configured".

### `windows_sysprep`

One resource, `unattend_file`, which writes the `unattend.xml` answer file
sysprep picks up (by default `C:\Windows\System32\Sysprep\unattend.xml`).
It never runs sysprep: generalizing an image ends the machine's life as a
configured system, and belongs in an image build, not a convergence step.

The structured params build an `oobeSystem` pass (OOBE screens, the
Administrator password, AutoLogon, FirstLogonCommands, locales, time zone);
`content` writes verbatim XML instead. Passwords are hidden the way Windows
SIM hides them (base64 of UTF-16LE, `PlainText=false`), which is obfuscation
rather than encryption, so the file is also restricted to SYSTEM and
Administrators on Windows and mode 0600 elsewhere. Pass passwords with
`secret()`. `architecture` defaults to the machine running the step; set it
when generating a file for an image of another architecture.
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
- `startup` includes `:automatic_delayed`. `:automatic` does not match a
  delayed-start service: applying it clears the delay.
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
  ProductCode. `version` is a [version range](#version-ranges) the
  installed `DisplayVersion` (or the value `version_value` names) must
  satisfy. Before msiexec runs, the package's own ProductCode and
  ProductVersion are checked against `product_id` and `version`.
  - When the same ProductCode is installed outside the range, the package
    is applied as a minor upgrade (`REINSTALL=ALL REINSTALLMODE=vomus`).
  - A major upgrade changes the ProductCode, so a new major version needs a
    new `product_id`.
  - `alt_product_id` (formerly `package_code`) is a second GUID to look for
    under the Uninstall key. `ensure = :absent` removes whichever GUID it
    finds.
  - Failures quote the error lines from msiexec's verbose log, which is
    kept under `C:\ProgramData\config-weave\installers\logs`.
- `exe_installer` runs an EXE installer. It detects the installation by
  `install_path`, `install_reg` or both. `version` is a
  [version range](#version-ranges) matched against `DisplayVersion` under
  `install_reg`, or the value `version_value` names, so `version` requires
  `install_reg`. Outside the range the installer at `path` runs, and must
  leave a version inside it. The Visual C++ runtime, for example, records
  its version as `Version` under its own key:

  ```wcl
  step "vc_runtime_x64" {
    resource = "windows_installers.exe_installer"
    properties {
      path          = "https://aka.ms/vs/17/release/vc_redist.x64.exe"
      args          = "/install /quiet /norestart"
      install_reg   = "HKLM\\SOFTWARE\\Microsoft\\VisualStudio\\14.0\\VC\\Runtimes\\x64"
      version_value = "Version"     # v14.38.33130.00
      version       = ">=14.38"
    }
  }
  ```

  Removal runs the first of these that is set:
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

- Chocolatey: `chocolatey_package` (with a `version` range),
  `chocolatey_source` (URL and `enabled`), `chocolatey_updated` and the
  `chocolatey_packages` gatherer. A package installed outside the
  [range](#version-ranges) is moved with `choco upgrade --version
  --allow-downgrade`, so the hold works in both directions: to the exact
  version given, or else to the newest that `choco search --exact
  --all-versions` lists inside the range. Chocolatey 1.x and 2.x are both supported: 1.x gets
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
- winget: `winget_installed`, `winget_package`, `winget_source` (URL and
  `type`), `winget_cache_updated` and the `winget_packages` gatherer.
  - `winget_installed` makes winget usable as SYSTEM. It installs the Visual
    C++ 2015-2022 runtime when it is missing (winget.exe run outside its
    package, as SYSTEM runs it, exits 0xC0000135 without it), provisions App
    Installer for every user when winget is missing, cannot start, is below
    `version` or is not provisioned, and writes a marked
    `C:\Windows\System32\winget.cmd` shim (`system_shim`). `method =
    :release` provisions the latest `microsoft/winget-cli` msixbundle and its
    dependencies (about 320 MB, size- and sha256-checked, retried);
    `:gallery` uses `Microsoft.WinGet.Client` and
    `Repair-WinGetPackageManager`, which needs PowerShell 7 and refuses
    `-AllUsers` as SYSTEM; `:auto` takes `:gallery` only where it can work
    and falls back to `:release`. `ensure = :absent` removes App Installer
    and the shim, and leaves the runtime. Windows marks App Installer
    `NonRemovable` wherever it is present (Server 2025 as shipped, Server
    2022 once provisioned), and there `:absent` is an error that changes
    nothing; `system_shim = false` drops just the shim.
  - `winget_package` holds a `version` [range](#version-ranges), or tracks
    the newest with `ensure = :latest` (`winget list --upgrade-available`).
    An installed package outside the range is reinstalled with `winget
    install --version --force`: at the exact version given, or else at the
    newest that `winget show --versions` lists inside the range. It
    takes `scope` (`:user`, `:machine`, compared through `winget list
    --scope`) and `installer_type` (`--installer-type`, e.g. `:wix` for the
    MSI build of `Microsoft.PowerShell`). `installer_type` and `source` pick
    how a package is installed and are not compared, because winget does
    not report either for an installed package. Exit code 0x8A150109
    reports `RebootRequired`, and 0x8A15002B (no applicable upgrade) is
    success.
  - Detection uses the `Microsoft.WinGet.Client` module if Windows
    PowerShell can load it, else `winget export`. The `winget list` table is
    never parsed, because its headers are localized and its columns are
    truncated; only its exit code is read.
  - Every winget resource and the gatherer run the newest `winget.exe`
    under `WindowsApps`, and use `PATH` only when there is none, so they need
    neither the shim nor an App Execution Alias. Put `winget_installed`
    first on a server.

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

### `windows_account`

Local and Active Directory users and groups:

- `local_user`, `local_group` and `local_group_member`: the SAM. Membership
  is compared by SID, read through ADSI, so a group holding an orphaned SID
  still works. A bare member name means the local account of that name only;
  write domain accounts and built-in principals qualified (`CORP\alice`,
  `NT AUTHORITY\NETWORK SERVICE`).
- `ad_user`, `ad_group` and `ad_group_member`: the directory, through the
  `ActiveDirectory` PowerShell module (RSAT-AD-PowerShell, present on every
  DC). `server` picks the DC or domain. `ou_path` is reconciled: an object
  outside it is moved. A group scope change between Global and DomainLocal
  steps through Universal. A member is resolved to one DN, which is both
  what check searches the group for and what apply writes.

Passwords reach PowerShell only through environment variables, so they are
never on a command line or in an error message; write them as
`secret("...")`. Password drift is detected by a logon attempt with the
wanted password and fixed by re-setting it, so there is no "force" flag. Each
check of a drifted password counts as one failed logon toward the account
lockout threshold.

### `windows_domain`

Domain controllers and domain membership:

- `domain_controller`: promotes and demotes. `mode` decides between creating
  a forest and joining an existing domain. The default `:auto` joins when a
  credential is given and creates a forest only when no DC answers and the
  name does not resolve, so a DNS hiccup cannot build a second forest of the
  same name. `ensure = :absent` only demotes a DC of `domain_name`.
- `domain_member`: joins (FQDN or NetBIOS name), renames to `new_name`,
  moves the computer account into `ou_path`, and leaves with
  `ensure = :absent`.
- `workgroup_member`: puts the machine in a workgroup, leaving its domain if
  it has one.
- `membership` gatherer: domain or workgroup, role, NetBIOS name, and the
  FSMO roles a DC holds (read over LDAP from the DC itself; `fsmo_known` is
  false when they could not be read).

Promotion needs the `AD-Domain-Services` feature with its management tools
installed first. Joining a domain, or promoting into one, needs the
machine's DNS pointed at a DC of it. Every change that needs a reboot
returns `RebootRequired`, and the step keeps reporting it until the machine
has rebooted. The `ad_matrix` scenario drives the whole lifecycle across
four VMs.

### `windows_network`

- `static_ip`: one manual IPv4 or IPv6 address per step, so several steps
  can share an interface. Only what differs is changed. `gateway` makes the
  interface's default routes exactly that one, and `exclusive` removes other
  manual addresses. Removing the last manual IPv4 address also removes its
  static routes and turns DHCP back on.
- `dns_servers`: the interface's static DNS servers, read from the registry
  rather than the effective list, so DHCP-assigned servers never count. An
  empty list removes them.
- `firewall_rule`: direction, action, protocol, profile, ports, remote
  addresses and enabled state, all compared the way Windows stores them.

Names and interface aliases holding wildcard characters (`*?[]`) are
refused, because the cmdlets would expand them to other rules or adapters.

### `windows_defender`

- `realtime_protection`: compared against the engine's effective state
  (`Get-MpComputerStatus`). Passive mode, a Group Policy value and Tamper
  Protection are reported as errors that name the cause.
- `exclusion`: path, extension, process and IP address exclusions.
- `preference`: any single `Set-MpPreference` setting. The value is
  converted to the setting's own type and compared in it: enums by name or
  number, times of day, numbers, booleans and lists.

Every resource needs Microsoft Defender Antivirus installed with its
`WinDefend` service running. When another antivirus product has taken over,
they fail with an error that says so. Just after boot, while the service is
running but Defender does not answer yet, they wait up to two minutes for it.

### `visual_studio`

- `instance` installs one Visual Studio 2017 to 2026 instance (Community,
  Professional, Enterprise, Build Tools or the test agent) and keeps its
  `workloads` and `components` installed. `version` is a major (`17`) or a
  vswhere range (`[16.0,17.0)`). `check` compares the listed ids with the
  packages vswhere reports for the instance, so it knows exactly which are
  missing.
  - Missing ids are added with the bootstrapper's `modify --add`. With
    `exact = true`, ids that were selected for the instance (its
    `state.json`) but are no longer listed are removed with `--remove`.
    Dependencies of listed items are never selected, so they stay.
  - Every installer operation goes through the bootstrapper
    (`https://aka.ms/vs/<major>/release/vs_<product>.exe`, `stable` for 18,
    or `bootstrapper`) with `--wait`. A download is retried three times
    and must carry a valid Authenticode signature before it runs.
  - Exit 3010 or 1641 is reported as reboot required. Any other failure
    names the exit code's meaning, the newest `dd_setup_*.log` (for SYSTEM
    under `C:\Windows\SystemTemp`) and the lines of its `_errors` log.
  - A running Visual Studio installer is waited for (up to 30 minutes)
    rather than fought with.
  - `product_key` goes in a response file (`--in`) that only SYSTEM and
    Administrators can read, never on a command line.
  - `ensure = :absent` uninstalls the instance.
- `instances` gatherer: every instance with its version, path, channel,
  installed workloads and selected ids.

**Not changed in place.** An instance on another channel than
`channel_url` is reported as an error (moving channels can change the
version line; use `setup.exe modifySettings`). `product_key` and
`include_recommended` apply when the installer runs; neither can be read
back from an instance.

Tests: four grouped VM tests install Build Tools 2022 with its MSBuild
workload, add a component, trim it again with `exact`, and uninstall.

### `vsix`

`extension` installs or removes one extension:

- `host = :visual_studio`: into every Visual Studio 2017 to 2026 instance
  that `vs_version` and `vs_products` select (Build Tools takes no
  extensions, so it never matches), with `VSIXInstaller.exe /quiet
  [/admin] /instanceIds:<id>`. Exit 1001 (already installed) is success.
  `check` looks for an `extension.vsixmanifest` whose Identity is `id`
  (and whose version satisfies the `version` [range](#version-ranges))
  under the instance's `Common7\IDE\Extensions` and
  `CommonExtensions` (`scope = :machine`) or the running account's
  `%LOCALAPPDATA%\Microsoft\VisualStudio\<major>.0_<instanceId>`
  (`scope = :user`; for SYSTEM also its `SysWOW64` twin, where the 32-bit
  VSIXInstaller's installs land). `source` is a path, a URL or a
  Marketplace item name (fetched at the exact `version`, or at the newest
  version the gallery lists inside the range, or at its newest version when
  `version` is empty); the package must carry `id`, at a version inside the
  range, before it is installed. Nothing runs while that instance's `devenv.exe` is open. A
  per-user uninstall only marks the directory for deletion at the next
  `devenv` start, so the resource deletes what VSIXInstaller left behind.
- `remove_parts` installs a copy of the package without some parts. The
  copy is made with `System.IO.Packaging`: signatures are removed, the
  parts deleted, their manifest `Location` dropped and `manifest.json`'s
  hashes brought up to date. Use it when a nested dependency is older than
  the copy already installed, which VSIXInstaller otherwise refuses.
- `host = :vscode`: through the `code` CLI (VS Code, Insiders or VSCodium,
  found in the usual install directories or set with `code`), compared on
  `--list-extensions --show-versions`. A Marketplace install with a range
  installs `id@<newest matching>`; pre-release versions are skipped. With `user`, the CLI gets
  `--extensions-dir` and `--user-data-dir` under that user's profile, so
  a run as SYSTEM installs for the user, not for SYSTEM.

This package does not depend on `visual_studio`; it carries its own
vswhere code. Run `visual_studio.instance` first (with `requires`) when
both are in one play.

Tests: Visual Studio Community 2022 with only the core editor, test
packages built in setup (plain, per-user, and a nested-dependency pair
in the shape of the SSAS/SSRS project extensions) plus one Marketplace
extension, and the portable VS Code zip with a local package for another
user and one pinned Marketplace extension. Visual Studio 2022 only takes
VSIX v3 packages (with `manifest.json` and `catalog.json`), so the test
packages carry both.

### `mssql`

Install and configure Microsoft SQL Server on **Windows** (silent `setup.exe`)
and **Linux** (the Microsoft repository plus `mssql-conf`), then converge
T-SQL-driven settings through `sqlcmd`. Every resource compares every param it
takes on an object that already exists and fixes the difference, and every
resource that creates something takes `ensure = :absent`.

- `instance`: install, reconcile or uninstall an instance, with `sqlcmd`
  (`install_tools`: go-sqlcmd on Windows, mssql-tools18 on Linux). Windows
  setup reads a generated `ConfigurationFile.ini` that only SYSTEM and
  Administrators can read, so `sa_password` never reaches a command line.
  On Windows each component in `features` is detected under its own
  `Instance Names` key (`SQL` for the engine, `OLAP` for Analysis Services,
  `RS` for the Reporting Services feature of 2016 and older), and a component
  missing from an existing instance is installed on its own. Analysis
  Services takes `as_server_mode`, `as_collation`, `as_sysadmin_accounts`
  and `as_data_dir`/`as_log_dir`/`as_temp_dir`/`as_backup_dir`; an AS-only
  install gets no engine options. Linux derives the repository from
  `/etc/os-release` and sets the collation at `mssql-conf setup`. On an
  existing instance it reconciles security mode, TCP, default directories,
  sysadmin accounts and the sa password (Windows engine), the AS collation,
  log/temp/backup directories (in `msmdsrv.ini`, with a service restart) and
  server administrators (through AMO), and the edition and sa password
  (Linux).
- `analysis_services_setting`: one Analysis Services server property, named
  as SSMS shows it (`ThreadPool\Process\MaxThreads`). It edits that element
  of the instance's `msmdsrv.ini` in place, keeping the rest of the file's
  bytes, and restarts the AS service only when the value changed.
- `reporting_services`: install, upgrade or uninstall SSRS 2017+ or Power BI
  Report Server from its standalone installer, with its edition and version
  compared on an installed server. `version` is a
  [version range](#version-ranges): `15.0` is any 15.0.x (SSRS 2019).
- `reporting_services_config`: what Report Server Configuration Manager
  does, through the report server's WMI provider: service account, catalogue
  database (created if missing, never dropped), the account's rights,
  database connection, web service and portal virtual directories and URLs,
  and initialisation. Covers SSRS 2016 to 2022 and Power BI Report Server.
- `mds_database`, `mds_web_application` (SQL Server 2019 and older): a
  Master Data Services database and its IIS web application, created the way
  MDS Configuration Manager creates them. MDS has no command line, so both
  call the internal classes of `Microsoft.MasterDataServices.Configuration.dll`
  through reflection, kept in `lib/mds.ws`. A newer MDS is refused with an
  error rather than guessed at. The web application needs the IIS role
  services Microsoft lists for MDS (it names any that are missing) and a
  Windows user as the pool identity.
- `server_setting`: any `sp_configure` value. It compares the configured value,
  so a restart-only option converges and warns until SQL Server restarts.
- `login`: SQL or Windows logins with password (compared with `PWDCOMPARE`),
  enabled state, default database and language, password policy and server
  roles.
- `database`: recovery model, collation (`ALTER DATABASE … COLLATE`), owner
  and compatibility level.
- `database_user`: login mapping (repairs orphaned users), default schema and
  roles.
- `database_cdc`, `cdc_table`: Change Data Capture at the database and table
  level.
- `tcp`: the TCP/IP protocol and static port (registry on Windows,
  `mssql-conf` on Linux), then an engine restart that brings SQL Server Agent,
  and any other running service that depends on the engine, back.
- `replication_distributor`, `replication_publisher`: a local distributor
  (retried until this server is registered as its publisher) and publishing
  databases.
- `database_mail`: a Database Mail profile and SMTP account.
- `agent_job`: a single-step Agent job with an optional managed schedule.
- `availability_group`: enable HADR (waiting for the restart) and create a
  single-replica availability group, `CLUSTER_TYPE = NONE` by default. Linux
  endpoints need `endpoint_certificate`.
- `instance_info` gatherer: version, edition, collation and HADR state.

Every T-SQL resource takes `server`, `instance`, `sql_user`, `sql_password` and
`trust_server_certificate`. Omit `sql_user` to use integrated (Windows)
authentication. `sql_password` reaches `sqlcmd` through `SQLCMDPASSWORD`, and
batches go in on stdin, so neither appears on a command line.
`trust_server_certificate` defaults to true for a local engine's self-signed
certificate; set it false for a remote server with a CA-issued one. Every
T-SQL resource needs `sqlcmd`, so run `instance` first or install the tools
yourself.

**Not changed in place.** These differences are reported as errors, never
ignored:

- a server collation (needs the system databases rebuilt);
- an Analysis Services server mode (fixed by setup) or data directory
  (moving it would orphan the databases under the old one);
- a Reporting Services install folder;
- an MDS database's collation or system administrator;
- a Windows edition (needs `setup.exe /ACTION=EditionUpgrade` with a key);
- a Linux major version (a one-way upgrade);
- a login's authentication type, unless `recreate_on_auth_change` is set;
- a CDC capture instance's options, unless `recreate_on_change` is set;
- an availability group's cluster type;
- the distribution database of a configured publisher.

Engine sub-features (`REPLICATION`, `FULLTEXT`, …) and shared features
(`IS`, `MDS`, …) in `features` apply only when their component is installed;
a whole missing component (engine, AS or RS) is added to an existing
instance. Database Mail cannot read back an
SMTP password, so bump `password_revision` to push a new one.

Tests: five container tests (`config_converges`, `reconcile`, `replication`,
`replication_absent`, `availability_group`) run against the official 2022
image. Two Ubuntu 24.04 VM tests cover the Linux install and removal, and the
`analysis_services_setting` Windows VM test edits two seeded `msmdsrv.ini`
files and compares them byte for byte. The `win_install` vmlab scenario
covers the Windows install, instance reconcile, TCP restart and availability
group; `win_bi` covers Analysis Services, Reporting Services and Master Data
Services on SQL Server 2019 (about 28 minutes, 1.5 GB of media).

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
guest. config-weave finds the installed release exe at
`~/.local/share/config-weave/bin/config-weave-windows-x86_64.exe` on its own,
so `just test windows_network` needs no extra setup once that file is in
place. Without it, a Windows test fails with "no windows test binary was
found".

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

### `linux_apt`, `linux_dnf` and `linux_zypper`

The three rpm and deb managers share a shape: `package`, `cache_updated`,
`repository`, a signing key resource and a hold or lock.

- `package` installs, pins an exact version, or removes. `version` is an
  exact pin, never a range: a value that starts with `^`, `~`, `>`, `<` or
  `=`, or holds `||`, a space or a `*` wildcard, or is or ends in an `x`
  part, is refused with an error saying distro packages take no ranges. A
  `~` or `-` inside a version (`1.0~rc1-1`) is an ordinary pin. A pin below the
  installed version is installed as a downgrade (`--allow-downgrades`,
  `downgrade`, `--oldpackage`); a pin installs once and does not stop
  upgrades, which is what the hold or lock is for. `:absent` refuses to
  remove a package that other installed packages depend on, since every
  manager would silently take them too, unless `remove_dependents = true`.
  A held or locked package is an error to change. On dnf and zypper, `name`
  may also be a capability or file path, and `version` matches `VERSION`,
  `VERSION-RELEASE` or `EPOCH:VERSION-RELEASE` on any installed instance.
  apt treats a removed package whose conffiles remain (`rc`) as absent.
- `cache_updated` refreshes when its own stamp is older than `max_age`, or
  when the manager's sources changed since (`/etc/apt/sources.list*`,
  `keyrings` and `trusted.gpg.d`; `/etc/yum.repos.d`; `/etc/zypp/repos.d`).
  dnf forces the refresh past `metadata_expire`; zypper treats a repository
  that fails to refresh as an error.
- `repository` — apt writes `<name>.list` or, with `format = :deb822`,
  `<name>.sources`; dnf writes a `.repo` file; zypper manages a repository
  by alias with `url`, `name`, `enabled`, `autorefresh` and `gpgcheck`.
- apt `signing_key` writes an armored `.asc` for `signed-by`; `dearmor =
  true` (default false, needs gpg) also keeps a binary `.gpg` current.
  dnf and zypper `gpg_key` import a key into the rpm database and check it
  there as well as its `/etc/pki/rpm-gpg/<name>.asc` copy; zypper's can
  fetch the key once from a `url`. No gpg is needed.
- apt `hold` (`apt-mark`), dnf `hold` (versionlock: needs dnf5-plugins,
  python3-dnf-plugin-versionlock or yum-plugin-versionlock) and zypper
  `lock` (`addlock`) match names exactly.
- apt `debconf_selection` pre-seeds an answer, compares its type, passes
  values through the environment (safe for `:password`), and with
  `:absent` unregisters the question.
- zypper: exit codes 100-103 are success and 102 reports `RebootRequired`;
  `gpg_auto_import_keys` opts in to `--gpg-auto-import-keys`.

apt waits up to five minutes for the dpkg lock and zypper for the zypp
lock. Resources that take the manager's lock also share a lock group, so
their steps never run at the same time, whatever their resource type:
apt's `package`, `cache_updated`, `hold` and `debconf_selection` (`"dpkg"`);
dnf's `package`, `cache_updated`, `gpg_key` and `hold` (`"rpmdb"`); every
zypper resource (`"zypp"`).

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

Every apk call waits up to five minutes for apk's database lock, and
`package` and `cache_updated` share the lock group `"apk-db"`.

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
for `db.lck` to go. `package`, `cache_updated`, `aur_package`,
`aur_cache_updated` and `key` share the lock group `"pacman-db"`;
`repository` and `hold`, which both rewrite `pacman.conf`, share
`"pacman-conf"`.

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

All three share the lock group `"flatpak"`, since flatpak takes one lock per
installation.

### Ordering

A lock group stops two steps that contend for the manager's lock running at
once, but it does not order them. Order them with `requires`, for example a
repository and its key before `cache_updated`, and `cache_updated` before
`package`.
