use value
use fs
use path
use common

// One file per job under /etc/cron.d keeps jobs independent (parallel-safe)
// and makes removal a simple delete. cron.d ignores names with a ".".
fn job_path(name: string) -> string { "/etc/cron.d/" + name }

fn desired(params: Value, name: string) -> string {
    let schedule = common::param_str(params, "schedule", "")
    let user = common::param_str(params, "user", "root")
    let command = common::param_str(params, "command", "")
    "# config-weave: " + name + "\n" + schedule + " " + user + " " + command + "\n"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !common::want_present(params)? {
        if fs::exists(job_path(name)) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if common::param_str(params, "schedule", "") == "" { return Err("missing 'schedule' parameter") }
    if common::param_str(params, "command", "") == "" { return Err("missing 'command' parameter") }
    let p = job_path(name)
    if fs::is_file(p) && fs::read(p)? == desired(params, name) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = job_path(name)
    if !common::want_present(params)? {
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    if common::param_str(params, "schedule", "") == "" { return Err("missing 'schedule' parameter") }
    if common::param_str(params, "command", "") == "" { return Err("missing 'command' parameter") }
    fs::mkdir(path::parent(p))?
    fs::write(p, desired(params, name))?
    Ok(ApplyResult::Success)
}
