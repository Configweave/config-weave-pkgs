use value
use registry

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

// WSUS settings straddle two keys: the server URLs and target group live on
// the WindowsUpdate key, while the switch that makes the client actually use
// them (UseWUServer) lives on the AU subkey.
fn wu_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate" }
fn au_key() -> string { "HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsUpdate\\AU" }

fn reg_str(key: string, name: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, name)? {
        return Ok(v.as_string().unwrap_or(""))
    }
    Ok("")
}

fn reg_int(key: string, name: string, fallback: int) -> Result[int, string] {
    if let Some(v) = registry::read(key, name)? {
        return Ok(v.as_int().unwrap_or(fallback))
    }
    Ok(fallback)
}

fn want_use_wsus(params: Value) -> Result[int, string] {
    let u = param_str(params, "use_wsus", "unmanaged")
    if u == "enabled" { return Ok(1) }
    if u == "disabled" { return Ok(0) }
    if u == "unmanaged" { return Ok(-1) }
    Err("invalid 'use_wsus' value '" + u + "' (expected :enabled, :disabled or :unmanaged)")
}

// An empty string means unmanaged; the status server defaults to the update
// server, which is what the GP UI does when the field is left blank.
fn status_server(params: Value) -> string {
    let s = param_str(params, "status_server", "")
    if s != "" { return s }
    param_str(params, "server", "")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let server = param_str(params, "server", "")
    if server != "" {
        if reg_str(wu_key(), "WUServer")? != server { return Ok(CheckResult::NotConfigured) }
        if reg_str(wu_key(), "WUStatusServer")? != status_server(params) { return Ok(CheckResult::NotConfigured) }
    }
    let group = param_str(params, "target_group", "")
    if group != "" {
        if reg_str(wu_key(), "TargetGroup")? != group { return Ok(CheckResult::NotConfigured) }
        if reg_int(wu_key(), "TargetGroupEnabled", 0)? != 1 { return Ok(CheckResult::NotConfigured) }
    }
    let use_wsus = want_use_wsus(params)?
    if use_wsus != -1 && reg_int(au_key(), "UseWUServer", 0)? != use_wsus {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let server = param_str(params, "server", "")
    if server != "" {
        registry::create_key(wu_key())?
        registry::write(wu_key(), "WUServer", Value::String(server), "sz")?
        registry::write(wu_key(), "WUStatusServer", Value::String(status_server(params)), "sz")?
    }
    let group = param_str(params, "target_group", "")
    if group != "" {
        registry::create_key(wu_key())?
        registry::write(wu_key(), "TargetGroup", Value::String(group), "sz")?
        registry::write(wu_key(), "TargetGroupEnabled", Value::Int(1), "dword")?
    }
    let use_wsus = want_use_wsus(params)?
    if use_wsus != -1 {
        registry::create_key(au_key())?
        registry::write(au_key(), "UseWUServer", Value::Int(use_wsus), "dword")?
    }
    Ok(ApplyResult::Success)
}
