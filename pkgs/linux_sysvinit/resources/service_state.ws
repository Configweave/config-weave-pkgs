use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn require_script(name: string) -> Result[unit, string] {
    if fs::is_file("/etc/init.d/" + name) { return Ok(()) }
    Err("init script does not exist: /etc/init.d/" + name)
}

fn desired_running(params: Value) -> Result[bool, string] {
    let state = param_str(params, "state", "")
    if state == "running" { return Ok(true) }
    if state == "stopped" { return Ok(false) }
    Err("invalid 'state' value '" + state + "' (expected running or stopped)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    require_script(name)?
    let out = shell::bash("/etc/init.d/" + q(name) + " status >/dev/null 2>&1", Value::Null)?
    if out.success == desired_running(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    require_script(name)?
    let verb = if desired_running(params)? { "start" } else { "stop" }
    let out = shell::bash("/etc/init.d/" + q(name) + " " + verb, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
