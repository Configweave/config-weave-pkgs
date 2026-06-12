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
    if fs::exists("/usr/bin/dnf") { return "dnf" }
    if fs::exists("/usr/bin/yum") { return "yum" }
    if fs::exists("/usr/bin/zypper") { return "zypper" }
    if fs::exists("/usr/bin/pacman") { return "pacman" }
    if fs::exists("/sbin/apk") || fs::exists("/usr/sbin/apk") { return "apk" }
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
    } else if m == "dnf" {
        "dnf makecache -y"
    } else if m == "yum" {
        "yum makecache -y"
    } else if m == "zypper" {
        "zypper --non-interactive refresh"
    } else if m == "pacman" {
        "pacman -Sy --noconfirm"
    } else if m == "apk" {
        "apk update"
    } else {
        return Err("unsupported package manager")
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let marker = param_str(params, "marker", "/var/lib/config-weave/package-cache-updated")
    fs::mkdir(path::parent(marker))?
    fs::write(marker, m + "\n")?
    Ok(ApplyResult::Success)
}

