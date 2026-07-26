use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn require_sv() -> Result[unit, string] {
    if fs::exists("/usr/bin/sv") || fs::exists("/bin/sv") || fs::exists("/usr/sbin/sv") { return Ok(()) }
    Err("sv not found; is runit installed?")
}

fn desired_running(params: Value) -> Result[bool, string] {
    let state = param_str(params, "state", "")
    if state == "running" { return Ok(true) }
    if state == "stopped" { return Ok(false) }
    Err("invalid 'state' value '" + state + "' (expected running or stopped)")
}

fn service_path(params: Value) -> string {
    param_str(params, "service_dir", "/var/service") + "/" + param_str(params, "name", "")
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_sv()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let out = shell::bash("sv status " + q(service_path(params)), Value::Null)?
    if !out.success { return Err(out.stderr.trim() + out.stdout.trim()) }
    // status lines start with "run:" or "down:"
    let running = out.stdout.trim().starts_with("run:")
    if running == desired_running(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_sv()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let verb = if desired_running(params)? { "up" } else { "down" }
    let out = shell::bash("sv " + verb + " " + q(service_path(params)), Value::Null)?
    if !out.success { return Err(out.stderr.trim() + out.stdout.trim()) }
    Ok(ApplyResult::Success)
}
