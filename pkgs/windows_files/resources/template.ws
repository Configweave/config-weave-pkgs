use value
use fs
use path
use template
use log

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

fn vars(params: Value) -> Value {
    if let Some(v) = params.get("vars") { return v }
    Value::Null
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // Rendering in `check` is what makes a variable change count as drift:
    // the file is compared against what the template produces now, not
    // against what it produced when it was written.
    let body = template::render(param_str(params, "template", ""), vars(params))?
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    if fs::read(p)? != body { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !want_present(params)? {
        if !fs::exists(p) { return Ok(ApplyResult::Success) }
        if fs::is_dir(p) { return Err("path is a directory; use windows_files.directory with ensure = :absent") }
        log::info("deleting " + p)
        fs::delete(p)?
        return Ok(ApplyResult::Success)
    }
    let body = template::render(param_str(params, "template", ""), vars(params))?
    log::info("rendering " + p)
    fs::mkdir(path::parent(p))?
    fs::write(p, body)?
    Ok(ApplyResult::Success)
}
