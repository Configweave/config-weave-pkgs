use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn manager(params: Value) -> string {
    let m = param_str(params, "manager", "auto")
    if m != "auto" { return m }
    if fs::exists("/usr/bin/apt-get") { return "apt" }
    if fs::exists("/usr/bin/dnf5") { return "dnf5" }
    if fs::exists("/usr/bin/dnf") { return "dnf" }
    if fs::exists("/usr/bin/microdnf") { return "microdnf" }
    if fs::exists("/usr/bin/yum") { return "yum" }
    if fs::exists("/usr/bin/tdnf") { return "tdnf" }
    if fs::exists("/usr/bin/zypper") { return "zypper" }
    if fs::exists("/usr/bin/pacman") { return "pacman" }
    if fs::exists("/sbin/apk") || fs::exists("/usr/sbin/apk") { return "apk" }
    if fs::exists("/usr/bin/xbps-install") { return "xbps" }
    if fs::exists("/usr/bin/emerge") { return "emerge" }
    if fs::exists("/usr/bin/eopkg") { return "eopkg" }
    if fs::exists("/usr/bin/swupd") { return "swupd" }
    if fs::exists("/usr/sbin/urpmi") || fs::exists("/usr/bin/urpmi") { return "urpmi" }
    if fs::exists("/usr/sbin/slackpkg") || fs::exists("/usr/bin/slackpkg") { return "slackpkg" }
    if fs::exists("/usr/bin/opkg") || fs::exists("/bin/opkg") { return "opkg" }
    if fs::exists("/usr/bin/rpm-ostree") { return "rpm-ostree" }
    if fs::exists("/usr/bin/flatpak") { return "flatpak" }
    if fs::exists("/usr/bin/snap") { return "snap" }
    if fs::exists("/usr/bin/nix-env") { return "nix" }
    if fs::exists("/usr/bin/guix") { return "guix" }
    "unknown"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let marker = param_str(params, "marker", "/var/lib/config-weave/package-cache-updated")
    if fs::exists(marker) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let m = manager(params)
    let cmd = if m == "apt" {
        "apt-get update"
    } else if m == "dnf5" {
        "dnf5 makecache -y"
    } else if m == "dnf" {
        "dnf makecache -y"
    } else if m == "microdnf" {
        "microdnf makecache"
    } else if m == "yum" {
        "yum makecache -y"
    } else if m == "tdnf" {
        "tdnf makecache -y"
    } else if m == "zypper" {
        "zypper --non-interactive refresh"
    } else if m == "pacman" {
        "pacman -Sy --noconfirm"
    } else if m == "apk" {
        "apk update"
    } else if m == "xbps" {
        "xbps-install -S"
    } else if m == "emerge" {
        "emerge --sync"
    } else if m == "eopkg" {
        "eopkg update-repo"
    } else if m == "swupd" {
        ""
    } else if m == "urpmi" {
        "urpmi.update -a"
    } else if m == "slackpkg" {
        "slackpkg -batch=on update"
    } else if m == "opkg" {
        "opkg update"
    } else if m == "rpm-ostree" {
        "rpm-ostree refresh-md"
    } else if m == "flatpak" {
        "flatpak update --appstream -y"
    } else if m == "snap" {
        ""
    } else if m == "nix" {
        "nix-channel --update"
    } else if m == "guix" {
        ""
    } else {
        return Err("unsupported package manager")
    }
    if cmd != "" {
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    let marker = param_str(params, "marker", "/var/lib/config-weave/package-cache-updated")
    fs::mkdir(path::parent(marker))?
    fs::write(marker, m + "\n")?
    Ok(ApplyResult::Success)
}
