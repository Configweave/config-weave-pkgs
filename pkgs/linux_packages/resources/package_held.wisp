use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn manager(params: Value) -> string {
    let m = param_str(params, "manager", "auto")
    if m != "auto" { return m }
    if fs::exists("/usr/bin/apt-mark") { return "apt" }
    if fs::exists("/usr/bin/dnf5") { return "dnf5" }
    if fs::exists("/usr/bin/dnf") { return "dnf" }
    if fs::exists("/usr/bin/yum") { return "yum" }
    "unknown"
}

fn is_held(name: string, m: string) -> Result[bool, string] {
    let cmd = if m == "apt" {
        "apt-mark showhold | grep -Fxq " + q(name)
    } else if m == "dnf5" || m == "dnf" || m == "yum" {
        m + " versionlock list 2>/dev/null | grep -Fq " + q(name)
    } else {
        return Err("hold is not supported for package manager '" + m + "'")
    }
    Ok(shell::bash(cmd, Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if is_held(name, manager(params))? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let m = manager(params)
    if name == "" { return Err("missing 'name' parameter") }
    let cmd = if m == "apt" {
        "apt-mark hold " + q(name)
    } else if m == "dnf5" || m == "dnf" || m == "yum" {
        m + " versionlock add " + q(name)
    } else {
        return Err("hold is not supported for package manager '" + m + "'")
    }
    let out = shell::bash(cmd, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
