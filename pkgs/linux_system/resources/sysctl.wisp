use value
use fs
use shell
use path

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }
fn dropin_path(key: string) -> string { "/etc/sysctl.d/99-config-weave-" + key.replace(".", "-") + ".conf" }

fn check(params: Value) -> Result[CheckResult, string] {
    let key = param_str(params, "key", "")
    let want = param_str(params, "value", "")
    if key == "" { return Err("missing 'key' parameter") }
    let out = shell::bash("sysctl -n " + q(key), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    if out.stdout.trim() != want { return Ok(CheckResult::NotConfigured) }
    if param_bool(params, "persist", false) {
        let p = dropin_path(key)
        if !fs::is_file(p) || fs::read(p)? != key + " = " + want + "\n" { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = param_str(params, "key", "")
    let want = param_str(params, "value", "")
    if key == "" { return Err("missing 'key' parameter") }
    let out = shell::bash("sysctl -w " + q(key + "=" + want), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    if param_bool(params, "persist", false) {
        let p = dropin_path(key)
        fs::mkdir(path::parent(p))?
        fs::write(p, key + " = " + want + "\n")?
    }
    Ok(ApplyResult::Success)
}

