use value
use fs
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn q(s: string) -> string { "'" + s.replace("'", "'\\''") + "'" }

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// :unmanaged means "do not look at this aspect" — it is what lets one
// resource install a service without also deciding whether it runs.
fn desired_state(params: Value) -> Result[string, string] {
    let s = param_str(params, "state", "unmanaged")
    if s == "running" || s == "stopped" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'state' value '" + s + "' (expected :running, :stopped or :unmanaged)")
}

fn desired_enabled(params: Value) -> Result[string, string] {
    let e = param_str(params, "enabled", "unmanaged")
    if e == "enabled" || e == "disabled" || e == "unmanaged" { return Ok(e) }
    Err("invalid 'enabled' value '" + e + "' (expected :enabled, :disabled or :unmanaged)")
}

fn require_openrc() -> Result[unit, string] {
    if fs::exists("/sbin/rc-update") || fs::exists("/usr/sbin/rc-update") || fs::exists("/bin/rc-update") { return Ok(()) }
    Err("rc-update not found; is OpenRC installed?")
}

fn script_path(name: string) -> string { "/etc/init.d/" + name }

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

// Only meaningful once the init script exists: `rc-service status` on an
// unknown service fails the same way a stopped one does.
fn running(name: string) -> Result[bool, string] {
    Ok(shell::bash("rc-service " + q(name) + " status >/dev/null 2>&1", Value::Null)?.success)
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_openrc()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let runlevel = param_str(params, "runlevel", "default")
    let p = script_path(name)
    if !want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        if in_runlevel(name, runlevel)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    // An empty `script` means "manage the service that is already there",
    // so the content is only drift when content was actually supplied.
    let script = param_str(params, "script", "")
    if script != "" && fs::read(p)? != script { return Ok(CheckResult::NotConfigured) }
    let en = desired_enabled(params)?
    if en != "unmanaged" && in_runlevel(name, runlevel)? != (en == "enabled") {
        return Ok(CheckResult::NotConfigured)
    }
    let st = desired_state(params)?
    if st != "unmanaged" && running(name)? != (st == "running") {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_openrc()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let runlevel = param_str(params, "runlevel", "default")
    let p = script_path(name)
    if !want_present(params)? {
        // Stop before unregistering, and unregister before deleting: OpenRC
        // cannot stop a service whose script has already gone.
        if fs::is_file(p) && running(name)? {
            let out = shell::bash("rc-service " + q(name) + " stop", Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
        if in_runlevel(name, runlevel)? {
            let out = shell::bash("rc-update del " + q(name) + " " + q(runlevel), Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
        if fs::exists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let script = param_str(params, "script", "")
    if script != "" {
        fs::write(p, script)?
        let out = shell::run("chmod +x " + p, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    } else if !fs::is_file(p) {
        return Err("no init script at " + p + " and no 'script' content was given")
    }
    let en = desired_enabled(params)?
    if en != "unmanaged" {
        let listed = in_runlevel(name, runlevel)?
        if listed != (en == "enabled") {
            let verb = if en == "enabled" { "add" } else { "del" }
            let out = shell::bash("rc-update " + verb + " " + q(name) + " " + q(runlevel), Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
    }
    let st = desired_state(params)?
    if st != "unmanaged" {
        let is_up = running(name)?
        if is_up != (st == "running") {
            let verb = if st == "running" { "start" } else { "stop" }
            let out = shell::bash("rc-service " + q(name) + " " + verb, Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
    }
    Ok(ApplyResult::Success)
}
