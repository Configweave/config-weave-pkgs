use value
use service

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn wanted(params: Value) -> Result[string, string] {
    let s = param_str(params, "startup", "")
    if s == "automatic" || s == "manual" || s == "disabled" { return Ok(s) }
    Err("invalid 'startup' value '" + s + "' (expected automatic, manual or disabled)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let want = wanted(params)?
    if service::startup(name)? == want { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    service::set_startup(name, wanted(params)?)?
    Ok(ApplyResult::Success)
}
