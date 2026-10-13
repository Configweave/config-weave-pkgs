use value
use fs
use path
use common

// One file per job under /etc/cron.d keeps jobs independent (parallel-safe)
// and makes removal a simple delete. cron reads only files whose names are
// letters, digits, underscores and hyphens (run-parts rules), so anything
// else is rejected rather than written and silently ignored; that also
// keeps the name from walking out of /etc/cron.d.
fn job_path(name: string) -> string { "/etc/cron.d/" + name }

fn validate_name(name: string) -> Result[unit, string] {
    if name == "" { return Err("missing 'name' parameter") }
    if !name.chars().all(|c| (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_' || c == '-') {
        return Err("invalid job name '" + name + "': cron.d only reads names made of letters, digits, '_' and '-'")
    }
    Ok(())
}

// schedule, user and command share one line of the crontab, so none may
// break it; a schedule and a user are single tokens apart from the
// schedule's own field separators.
fn validate_entry(params: Value) -> Result[unit, string] {
    let schedule = common::param_str(params, "schedule", "").trim()
    let command = common::param_str(params, "command", "")
    let user = common::param_str(params, "user", "root")
    if schedule == "" { return Err("missing 'schedule' parameter") }
    if command.trim() == "" { return Err("missing 'command' parameter") }
    common::one_line("schedule", schedule)?
    common::one_line("command", command)?
    common::one_line("user", user)?
    if user == "" || common::has_space(user) { return Err("invalid 'user' value '" + user + "'") }
    let fields = schedule.replace("\t", " ").split(" ").filter(|f| f != "")
    if schedule.starts_with("@") { if fields.len() != 1 { return Err("invalid schedule '" + schedule + "'") } }
    else if fields.len() != 5 { return Err("invalid schedule '" + schedule + "' (expected five fields or an @keyword)") }
    Ok(())
}

fn desired(params: Value, name: string) -> string {
    let schedule = common::param_str(params, "schedule", "").trim()
    let user = common::param_str(params, "user", "root")
    let command = common::param_str(params, "command", "")
    "# config-weave: " + name + "\n" + schedule + " " + user + " " + command + "\n"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    validate_name(name)?
    let p = job_path(name)
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    validate_entry(params)?
    if fs::is_file(p) && fs::read(p).unwrap_or("") == desired(params, name) { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    validate_name(name)?
    let p = job_path(name)
    if !common::want_present(params)? {
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    validate_entry(params)?
    fs::mkdir(path::parent(p))?
    common::write_atomic(p, desired(params, name))?
    Ok(ApplyResult::Success)
}
