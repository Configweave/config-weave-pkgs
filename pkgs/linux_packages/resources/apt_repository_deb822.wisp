use value
use fs
use path

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn repo_path(name: string) -> string {
    "/etc/apt/sources.list.d/" + name + ".sources"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let content = param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = repo_path(name)
    if fs::is_file(p) && fs::read(p)? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let content = param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = repo_path(name)
    fs::mkdir(path::parent(p))?
    fs::write(p, content)?
    Ok(ApplyResult::Success)
}
