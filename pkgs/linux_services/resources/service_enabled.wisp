use value
use shell
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }
fn has_systemctl() -> bool { fs::exists("/bin/systemctl") || fs::exists("/usr/bin/systemctl") }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let enabled = param_bool(params, "enabled", false)
    if name == "" { return Err("missing 'name' parameter") }
    if !has_systemctl() { return Err("systemctl is not available on this host") }
    let is_enabled = shell::bash("systemctl is-enabled --quiet " + q(name), Value::Null)?.success
    if is_enabled == enabled { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let enabled = param_bool(params, "enabled", false)
    if name == "" { return Err("missing 'name' parameter") }
    let action = if enabled { "enable" } else { "disable" }
    let out = shell::bash("systemctl " + action + " " + q(name), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

