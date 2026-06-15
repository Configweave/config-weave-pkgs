use value
use fs
use path
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

// The ASCII-armored key is the source of truth (content-compared); a
// binary .gpg keyring is derived from it when dearmor is requested.
fn asc_path(name: string) -> string { "/etc/apt/keyrings/" + name + ".asc" }
fn gpg_path(name: string) -> string { "/etc/apt/keyrings/" + name + ".gpg" }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let content = param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let asc = asc_path(name)
    if !fs::is_file(asc) || fs::read(asc)? != content { return Ok(CheckResult::NotConfigured) }
    if param_bool(params, "dearmor", true) && !fs::is_file(gpg_path(name)) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let content = param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let asc = asc_path(name)
    fs::mkdir(path::parent(asc))?
    fs::write(asc, content)?
    if param_bool(params, "dearmor", true) {
        let out = shell::bash("gpg --batch --yes --dearmor -o " + q(gpg_path(name)) + " " + q(asc), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    }
    Ok(ApplyResult::Success)
}
