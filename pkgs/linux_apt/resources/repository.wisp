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

fn repo_path(name: string) -> string {
    "/etc/apt/sources.list.d/" + name + ".list"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = repo_path(name)
    if !want_present(params)? {
        if fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let content = param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    if fs::is_file(p) && fs::read(p)? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = repo_path(name)
    if !want_present(params)? {
        if fs::is_file(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let content = param_str(params, "content", "")
    if content == "" { return Err("missing 'content' parameter") }
    fs::mkdir(path::parent(p))?
    fs::write(p, content)?
    Ok(ApplyResult::Success)
}
