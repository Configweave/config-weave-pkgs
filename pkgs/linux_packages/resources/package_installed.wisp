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
    if fs::exists("/usr/bin/dnf") { return "dnf" }
    if fs::exists("/usr/bin/yum") { return "yum" }
    if fs::exists("/usr/bin/zypper") { return "zypper" }
    if fs::exists("/usr/bin/pacman") { return "pacman" }
    if fs::exists("/sbin/apk") || fs::exists("/usr/sbin/apk") { return "apk" }
    "unknown"
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn installed(name: string, m: string) -> Result[bool, string] {
    let cmd = if m == "apt" {
        "dpkg -s " + q(name) + " >/dev/null 2>&1"
    } else if m == "dnf" || m == "yum" || m == "zypper" {
        "rpm -q " + q(name) + " >/dev/null 2>&1"
    } else if m == "pacman" {
        "pacman -Q " + q(name) + " >/dev/null 2>&1"
    } else if m == "apk" {
        "apk info -e " + q(name) + " >/dev/null 2>&1"
    } else {
        return Err("unsupported package manager")
    }
    Ok(shell::bash(cmd, Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if installed(name, manager(params))? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let m = manager(params)
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if m == "apt" {
        "DEBIAN_FRONTEND=noninteractive apt-get install -y " + q(name)
    } else if m == "dnf" {
        "dnf install -y " + q(name)
    } else if m == "yum" {
        "yum install -y " + q(name)
    } else if m == "zypper" {
        "zypper --non-interactive install " + q(name)
    } else if m == "pacman" {
        "pacman -S --noconfirm " + q(name)
    } else if m == "apk" {
        "apk add " + q(name)
    } else {
        return Err("unsupported package manager")
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

