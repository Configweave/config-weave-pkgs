use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected \"present\" or \"absent\")")
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
        "test \"$(dpkg-query -W -f='${{db:Status-Status}}' " + q(name) + " 2>/dev/null)\" = installed"
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

// Version pinning is supported only on managers with a predictable
// "name + sep + version" install spec and a queryable installed version.
fn supports_version(m: string) -> bool {
    m == "apt" || m == "dnf5" || m == "dnf" || m == "microdnf" || m == "yum" || m == "tdnf" || m == "zypper"
}

// The installed version string, or "" when not installed / unknown.
fn installed_version(name: string, m: string) -> Result[string, string] {
    let cmd = if m == "apt" {
        "dpkg-query -W -f='${{Version}}' " + q(name) + " 2>/dev/null"
    } else {
        "rpm -q --qf '%{{VERSION}}' " + q(name) + " 2>/dev/null"
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Ok("") }
    Ok(out.stdout.trim())
}

// The install spec for a pinned version, per manager.
fn versioned_spec(name: string, version: string, m: string) -> string {
    if m == "apt" || m == "zypper" {
        name + "=" + version
    } else {
        name + "-" + version
    }
}

fn remove_cmd(name: string, m: string) -> Result[string, string] {
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
    Ok(cmd)
}

fn install_cmd(name: string, target: string, m: string) -> Result[string, string] {
    let cmd = if m == "apt" {
        "DEBIAN_FRONTEND=noninteractive apt-get install -y " + q(target)
    } else if m == "dnf5" {
        "dnf5 install -y " + q(target)
    } else if m == "dnf" {
        "dnf install -y " + q(target)
    } else if m == "microdnf" {
        "microdnf install -y " + q(target)
    } else if m == "yum" {
        "yum install -y " + q(target)
    } else if m == "tdnf" {
        "tdnf install -y " + q(target)
    } else if m == "zypper" {
        "zypper --non-interactive install " + q(target)
    } else if m == "pacman" {
        "pacman -S --noconfirm " + q(name)
    } else if m == "apk" {
        "apk add " + q(name)
    } else if m == "xbps" {
        "xbps-install -y " + q(name)
    } else if m == "emerge" {
        "emerge --noreplace " + q(name)
    } else if m == "eopkg" {
        "eopkg install -y " + q(name)
    } else if m == "swupd" {
        "swupd bundle-add " + q(name)
    } else if m == "urpmi" {
        "urpmi --auto " + q(name)
    } else if m == "slackpkg" {
        "slackpkg -batch=on -default_answer=y install " + q(name)
    } else if m == "opkg" {
        "opkg install " + q(name)
    } else if m == "rpm-ostree" {
        "rpm-ostree install " + q(name)
    } else if m == "flatpak" {
        "flatpak install -y " + q(name)
    } else if m == "snap" {
        "snap install " + q(name)
    } else if m == "nix" {
        "nix-env -iA nixpkgs." + name
    } else if m == "guix" {
        "guix package --install " + q(name)
    } else {
        return Err("unsupported package manager")
    }
    Ok(cmd)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    let m = manager(params)
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        // existence probe only: any installed version means work to do
        if installed(name, m)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if version == "" {
        if installed(name, m)? { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if !supports_version(m) { return Err("version pinning is not supported for package manager '" + m + "'") }
    if installed_version(name, m)? == version { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let version = param_str(params, "version", "")
    let m = manager(params)
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if want_present(params)? {
        if version != "" && !supports_version(m) {
            return Err("version pinning is not supported for package manager '" + m + "'")
        }
        let target = if version != "" { versioned_spec(name, version, m) } else { name }
        install_cmd(name, target, m)?
    } else {
        remove_cmd(name, m)?
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
