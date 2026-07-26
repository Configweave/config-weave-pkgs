use value
use fs
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

fn require_openrc() -> Result[unit, string] {
    if fs::exists("/sbin/rc-update") || fs::exists("/usr/sbin/rc-update") || fs::exists("/bin/rc-update") { return Ok(()) }
    Err("rc-update not found; is OpenRC installed?")
}

fn in_runlevel(name: string, runlevel: string) -> Result[bool, string] {
    let out = shell::bash("rc-update show " + q(runlevel), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    for line in out.stdout.split("\n") {
        // lines look like " sshd | default"
        let parts = line.split("|")
        if parts.get(0).unwrap_or("").trim() == name { return Ok(true) }
    }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_openrc()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let listed = in_runlevel(name, param_str(params, "runlevel", "default"))?
    if listed == param_bool(params, "enabled", true) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_openrc()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let runlevel = param_str(params, "runlevel", "default")
    let verb = if param_bool(params, "enabled", true) { "add" } else { "del" }
    let out = shell::bash("rc-update " + verb + " " + q(name) + " " + q(runlevel), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
