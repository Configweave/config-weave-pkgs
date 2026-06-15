use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn key_path(name: string) -> string { "/etc/pki/rpm-gpg/" + name + ".asc" }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    let content = param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = key_path(name)
    if fs::is_file(p) && fs::read(p)? == content { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    let content = param_str(params, "content", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = key_path(name)
    fs::mkdir(path::parent(p))?
    fs::write(p, content)?
    // rpm --import is idempotent: re-importing the same key is a no-op.
    let out = shell::bash("rpm --import " + q(p), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
