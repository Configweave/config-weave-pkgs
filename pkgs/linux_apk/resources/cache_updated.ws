use value
use fs
use path
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn check(params: Value) -> Result[CheckResult, string] {
    let marker = param_str(params, "marker", "/var/lib/config-weave/package-cache-updated")
    if fs::exists(marker) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let out = shell::bash("apk update", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let marker = param_str(params, "marker", "/var/lib/config-weave/package-cache-updated")
    fs::mkdir(path::parent(marker))?
    fs::write(marker, "apk\n")?
    Ok(ApplyResult::Success)
}
