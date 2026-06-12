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

