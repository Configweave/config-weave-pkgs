use value
use fs
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

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn installed(name: string, m: string) -> Result[bool, string] {
    let cmd = if m == "apt" {
        // dpkg -s exits 0 even for a removed package whose conffiles remain
        // ("rc" state), so inspect the status field instead.
        "test \"$(dpkg-query -W -f='${db:Status-Status}' " + q(name) + " 2>/dev/null)\" = installed"
    } else if m == "dnf5" || m == "dnf" || m == "microdnf" || m == "yum" || m == "tdnf" || m == "zypper" || m == "rpm-ostree" {
        "rpm -q " + q(name) + " >/dev/null 2>&1"
    } else if m == "pacman" {
        "pacman -Q " + q(name) + " >/dev/null 2>&1"
    } else if m == "apk" {
        "apk info -e " + q(name) + " >/dev/null 2>&1"
    } else if m == "xbps" {
        "xbps-query " + q(name) + " >/dev/null 2>&1"
    } else if m == "emerge" {
        "qlist -IC " + q(name) + " >/dev/null 2>&1 || has_version " + q(name) + " >/dev/null 2>&1"
    } else if m == "eopkg" {
        "eopkg info " + q(name) + " >/dev/null 2>&1"
    } else if m == "swupd" {
        "swupd bundle-list | grep -Fx " + q(name) + " >/dev/null 2>&1"
    } else if m == "urpmi" {
        "rpm -q " + q(name) + " >/dev/null 2>&1"
    } else if m == "slackpkg" {
        "find /var/log/packages -maxdepth 1 -type f -name " + q(name + "-*") + " | grep -q ."
    } else if m == "opkg" {
        "opkg status " + q(name) + " 2>/dev/null | grep -Fx 'Status: install user installed' >/dev/null"
    } else if m == "flatpak" {
        "flatpak info " + q(name) + " >/dev/null 2>&1"
    } else if m == "snap" {
        "snap list " + q(name) + " >/dev/null 2>&1"
    } else if m == "nix" {
        "nix-env -q " + q(name) + " >/dev/null 2>&1"
    } else if m == "guix" {
        "guix package --list-installed=" + q(name) + " | grep -q ."
    } else {
        return Err("unsupported package manager")
    }
    Ok(shell::bash(cmd, Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if installed(name, manager(params))? { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let m = manager(params)
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if m == "apt" {
        "DEBIAN_FRONTEND=noninteractive apt-get remove -y " + q(name)
    } else if m == "dnf5" {
        "dnf5 remove -y " + q(name)
    } else if m == "dnf" {
        "dnf remove -y " + q(name)
    } else if m == "microdnf" {
        "microdnf remove -y " + q(name)
    } else if m == "yum" {
        "yum remove -y " + q(name)
    } else if m == "tdnf" {
        "tdnf remove -y " + q(name)
    } else if m == "zypper" {
        "zypper --non-interactive remove " + q(name)
    } else if m == "pacman" {
        "pacman -R --noconfirm " + q(name)
    } else if m == "apk" {
        "apk del " + q(name)
    } else if m == "xbps" {
        "xbps-remove -y " + q(name)
    } else if m == "emerge" {
        "emerge --deselect " + q(name) + " && emerge --depclean"
    } else if m == "eopkg" {
        "eopkg remove -y " + q(name)
    } else if m == "swupd" {
        "swupd bundle-remove " + q(name)
    } else if m == "urpmi" {
        "urpme --auto " + q(name)
    } else if m == "slackpkg" {
        "slackpkg -batch=on -default_answer=y remove " + q(name)
    } else if m == "opkg" {
        "opkg remove " + q(name)
    } else if m == "rpm-ostree" {
        "rpm-ostree uninstall " + q(name)
    } else if m == "flatpak" {
        "flatpak uninstall -y " + q(name)
    } else if m == "snap" {
        "snap remove " + q(name)
    } else if m == "nix" {
        "nix-env -e " + q(name)
    } else if m == "guix" {
        "guix package --remove " + q(name)
    } else {
        return Err("unsupported package manager")
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
