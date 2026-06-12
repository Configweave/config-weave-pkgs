use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }
fn has_firewall_cmd() -> bool { fs::exists("/usr/bin/firewall-cmd") || fs::exists("/bin/firewall-cmd") }

fn base_args(params: Value) -> string {
    let zone = param_str(params, "zone", "")
    let permanent = param_bool(params, "permanent", true)
    (if permanent { " --permanent" } else { "" }) + if zone != "" { " --zone=" + q(zone) } else { "" }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let svc = param_str(params, "service", "")
    if svc == "" { return Err("missing 'service' parameter") }
    if !has_firewall_cmd() { return Err("firewall-cmd is not available") }
    let enabled = param_bool(params, "enabled", true)
    let out = shell::bash("firewall-cmd" + base_args(params) + " --query-service=" + q(svc), Value::Null)?
    let has = out.success
    if has == enabled { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let svc = param_str(params, "service", "")
    let enabled = param_bool(params, "enabled", true)
    if svc == "" { return Err("missing 'service' parameter") }
    if !has_firewall_cmd() { return Err("firewall-cmd is not available") }
    let action = if enabled { " --add-service=" } else { " --remove-service=" }
    let out = shell::bash("firewall-cmd" + base_args(params) + action + q(svc), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}

