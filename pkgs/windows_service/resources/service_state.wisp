use value
use service

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn wanted(params: Value) -> Result[string, string] {
    let s = param_str(params, "state", "")
    if s == "running" || s == "stopped" { return Ok(s) }
    Err("invalid 'state' value '" + s + "' (expected running or stopped)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let want = wanted(params)?
    // Transitional states (start_pending, stop_pending, paused, ...) count as
    // not yet configured; apply nudges them to the target.
    if service::status(name)? == want { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if wanted(params)? == "running" {
        service::start(name)?
    } else {
        service::stop(name)?
    }
    Ok(ApplyResult::Success)
}
