use value
use fs
use path

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        // read_link (not fs::exists, which follows the link and lies
        // about dangling symlinks) probes the link itself.
        if fs::read_link(p).is_ok() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let target = param_str(params, "target", "")
    if target == "" { return Err("missing 'target' parameter") }
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    if fs::read_link(p).unwrap_or("") == target { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        // deletes the link itself, never its target
        if fs::read_link(p).is_ok() { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let target = param_str(params, "target", "")
    if target == "" { return Err("missing 'target' parameter") }
    fs::mkdir(path::parent(p))?
    if fs::exists(p) { fs::delete(p)? }
    fs::symlink(target, p)?
    Ok(ApplyResult::Success)
}
