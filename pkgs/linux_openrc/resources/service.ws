use value
use fs
use shell
use common

fn require_openrc() -> Result[unit, string] {
    if fs::exists("/sbin/rc-update") || fs::exists("/usr/sbin/rc-update") || fs::exists("/bin/rc-update") { return Ok(()) }
    Err("rc-update not found; is OpenRC installed?")
}

fn script_path(name: string) -> string { "/etc/init.d/" + name }

fn in_runlevel(name: string, runlevel: string) -> Result[bool, string] {
    let out = shell::bash("rc-update show " + common::q(runlevel), Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    for line in out.stdout.split("\n") {
        // lines look like " sshd | default"
        let parts = line.split("|")
        if parts.get(0).unwrap_or("").trim() == name { return Ok(true) }
    }
    Ok(false)
}

// Only meaningful once the init script exists: `rc-service status` on an
// unknown service fails the same way a stopped one does.
fn running(name: string) -> Result[bool, string] {
    Ok(shell::bash("rc-service " + common::q(name) + " status >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_openrc()?
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let runlevel = common::param_str(params, "runlevel", "default")
    let p = script_path(name)
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        if in_runlevel(name, runlevel)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    // An empty `script` means "manage the service that is already there",
    // so the content is only drift when content was actually supplied.
    let script = common::param_str(params, "script", "")
    if script != "" && fs::read(p)? != script { return Ok(CheckResult::NotConfigured) }
    let en = common::desired_enabled(params)?
    if en != "unmanaged" && in_runlevel(name, runlevel)? != (en == "enabled") {
        return Ok(CheckResult::NotConfigured)
    }
    let st = common::desired_state(params)?
    if st != "unmanaged" && running(name)? != (st == "running") {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_openrc()?
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let runlevel = common::param_str(params, "runlevel", "default")
    let p = script_path(name)
    if !common::want_present(params)? {
        // Stop before unregistering, and unregister before deleting: OpenRC
        // cannot stop a service whose script has already gone.
        if fs::is_file(p) && running(name)? {
            let out = shell::bash("rc-service " + common::q(name) + " stop", Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
        if in_runlevel(name, runlevel)? {
            let out = shell::bash("rc-update del " + common::q(name) + " " + common::q(runlevel), Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let script = common::param_str(params, "script", "")
    if script != "" {
        fs::write(p, script)?
        let out = shell::run("chmod +x " + p, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    } else if !fs::is_file(p) {
        return Err("no init script at " + p + " and no 'script' content was given")
    }
    let en = common::desired_enabled(params)?
    if en != "unmanaged" {
        let listed = in_runlevel(name, runlevel)?
        if listed != (en == "enabled") {
            let verb = if en == "enabled" { "add" } else { "del" }
            let out = shell::bash("rc-update " + verb + " " + common::q(name) + " " + common::q(runlevel), Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
    }
    let st = common::desired_state(params)?
    if st != "unmanaged" {
        let is_up = running(name)?
        if is_up != (st == "running") {
            let verb = if st == "running" { "start" } else { "stop" }
            let out = shell::bash("rc-service " + common::q(name) + " " + verb, Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
    }
    Ok(ApplyResult::Success)
}
