use value
use shell
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }
fn has_systemctl() -> bool { fs::exists("/bin/systemctl") || fs::exists("/usr/bin/systemctl") }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let state = param_str(params, "state", "")
    if name == "" { return Err("missing 'name' parameter") }
    if state != "running" && state != "stopped" { return Err("state must be running or stopped") }
    if !has_systemctl() { return Err("systemctl is not available on this host") }
    let active = shell::bash("systemctl is-active --quiet " + q(name), Value::Null)?.success
    if (state == "running" && active) || (state == "stopped" && !active) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let state = param_str(params, "state", "")
    if name == "" { return Err("missing 'name' parameter") }
    let action = if state == "running" { "start" } else if state == "stopped" { "stop" } else { return Err("state must be running or stopped") }
    let out = shell::bash("systemctl " + action + " " + q(name), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

