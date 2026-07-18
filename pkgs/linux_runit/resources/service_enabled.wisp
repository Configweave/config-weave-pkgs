use value
use fs

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn link_path(params: Value) -> string {
    param_str(params, "service_dir", "/var/service") + "/" + param_str(params, "name", "")
}

fn sv_path(params: Value) -> string {
    param_str(params, "sv_dir", "/etc/sv") + "/" + param_str(params, "name", "")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let linked = fs::read_link(link_path(params)).is_ok()
    if linked == param_bool(params, "enabled", true) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let link = link_path(params)
    if param_bool(params, "enabled", true) {
        let src = sv_path(params)
        if !fs::is_dir(src) { return Err("service definition does not exist: " + src) }
        if fs::read_link(link).is_ok() { fs::delete(link)? }
        fs::symlink(src, link)?
        return Ok(ApplyResult::Success)
    }
    // removing the link stops supervision; runsvdir notices the removal
    if fs::read_link(link).is_ok() { fs::delete(link)? }
    Ok(ApplyResult::Success)
}
