# config-weave-pkgs

Standard Linux package library for Config Weave.

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

- `linux_facts`: Linux OS, package manager, init system and network facts.
- `linux_files`: files, directories, symlinks, downloads, line edits and modes.
- `linux_packages`: package-manager resources for common Linux distributions.
- `linux_services`: service state, service enablement and systemd unit files.
- `linux_accounts`: users, groups, SSH authorized keys and sudoers drop-ins.
- `linux_system`: sysctl, hostname, timezone, locale, cron, logrotate and fstab.
- `linux_network`: hosts entries, SSH config snippets and firewall front-ends.

## Development

```sh
just validate
just test
just docs
```

`just test` needs Docker or Podman and a Linux Config Weave binary, following the
Config Weave testlab rules.

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
