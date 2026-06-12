use value
use fs
use path

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    let target = param_str(params, "target", "")
    if p == "" { return Err("missing 'path' parameter") }
    if target == "" { return Err("missing 'target' parameter") }
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    if fs::read_link(p).unwrap_or("") == target { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    let target = param_str(params, "target", "")
    if p == "" { return Err("missing 'path' parameter") }
    if target == "" { return Err("missing 'target' parameter") }
    fs::mkdir(path::parent(p))?
    if fs::exists(p) { fs::delete(p)? }
    fs::symlink(target, p)?
    Ok(ApplyResult::Success)
}

