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
    Err("invalid 'ensure' value '" + e + "' (expected \"present\" or \"absent\")")
}

// One file per job under /etc/cron.d keeps jobs independent (parallel-safe)
// and makes removal a simple delete. cron.d ignores names with a ".".
fn job_path(name: string) -> string { "/etc/cron.d/" + name }

fn desired(params: Value, name: string) -> string {
    let schedule = param_str(params, "schedule", "")
    let user = param_str(params, "user", "root")
    let command = param_str(params, "command", "")
    "# config-weave: " + name + "\n" + schedule + " " + user + " " + command + "\n"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        if fs::exists(job_path(name)) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if param_str(params, "schedule", "") == "" { return Err("missing 'schedule' parameter") }
    if param_str(params, "command", "") == "" { return Err("missing 'command' parameter") }
    let p = job_path(name)
    if fs::is_file(p) && fs::read(p)? == desired(params, name) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = job_path(name)
    if !want_present(params)? {
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    if param_str(params, "schedule", "") == "" { return Err("missing 'schedule' parameter") }
    if param_str(params, "command", "") == "" { return Err("missing 'command' parameter") }
    fs::mkdir(path::parent(p))?
    fs::write(p, desired(params, name))?
    Ok(ApplyResult::Success)
}
