use value
use fs
use path
use shell
use time

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

fn require_sv() -> Result[unit, string] {
    if fs::exists("/usr/bin/sv") || fs::exists("/bin/sv") || fs::exists("/usr/sbin/sv") { return Ok(()) }
    Err("sv not found; is runit installed?")
}

// A runit service is a directory holding an executable `run` script; it is
// activated by symlinking that directory into the supervised service dir.
fn sv_path(params: Value) -> string {
    param_str(params, "sv_dir", "/etc/sv") + "/" + param_str(params, "name", "")
}

fn run_path(params: Value) -> string { sv_path(params) + "/run" }

fn link_path(params: Value) -> string {
    param_str(params, "service_dir", "/var/service") + "/" + param_str(params, "name", "")
}

fn linked(params: Value) -> bool { fs::read_link(link_path(params)).is_ok() }

// runsvdir rescans its directory on a timer, so a freshly linked service is
// not supervised the instant the symlink appears — `sv up` against it fails
// with "unable to open supervise/ok". Wait for runsv to claim it.
fn await_supervision(link: string) -> Result[unit, string] {
    for i in 0..60 {
        if fs::exists(link + "/supervise/ok") { return Ok(()) }
        time::sleep(500)
    }
    Err("timed out waiting for runsvdir to supervise " + link)
}

// Only meaningful while the service is linked: runsvdir supervises the
// symlinked directory, and `sv status` on an unsupervised one fails.
fn running(params: Value) -> Result[bool, string] {
    let out = shell::bash("sv status " + q(link_path(params)), Value::Null)?
    if !out.success { return Ok(false) }
    // status lines start with "run:" or "down:"
    Ok(out.stdout.trim().starts_with("run:"))
}

fn check(params: Value) -> Result[CheckResult, string] {
    require_sv()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        if linked(params) { return Ok(CheckResult::NotConfigured) }
        if fs::exists(sv_path(params)) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(run_path(params)) { return Ok(CheckResult::NotConfigured) }
    // An empty `run` means "manage the service definition that is already
    // there", so content is only drift when content was actually supplied.
    let body = param_str(params, "run", "")
    if body != "" && fs::read(run_path(params))? != body { return Ok(CheckResult::NotConfigured) }
    let en = desired_enabled(params)?
    if en != "unmanaged" && linked(params) != (en == "enabled") {
        return Ok(CheckResult::NotConfigured)
    }
    let st = desired_state(params)?
    if st != "unmanaged" && running(params)? != (st == "running") {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    require_sv()?
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let link = link_path(params)
    if !want_present(params)? {
        // Unlinking is what stops supervision — runsvdir notices the removal
        // — so it comes before deleting the definition.
        if linked(params) { fs::delete(link)? }
        if fs::exists(sv_path(params)) { fs::delete_dir(sv_path(params))? }
        return Ok(ApplyResult::Success)
    }
    let body = param_str(params, "run", "")
    if body != "" {
        fs::mkdir(sv_path(params))?
        fs::write(run_path(params), body)?
        let out = shell::run("chmod +x " + run_path(params), Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
    } else if !fs::is_file(run_path(params)) {
        return Err("no run script at " + run_path(params) + " and no 'run' content was given")
    }
    let en = desired_enabled(params)?
    if en != "unmanaged" {
        let is_linked = linked(params)
        if is_linked != (en == "enabled") {
            if en == "enabled" {
                fs::mkdir(path::parent(link))?
                fs::symlink(sv_path(params), link)?
            } else {
                fs::delete(link)?
            }
        }
    }
    let st = desired_state(params)?
    if st != "unmanaged" {
        // An unlinked service has no supervisor to talk to, so there is no
        // runtime state to enforce.
        if !linked(params) {
            return Err("cannot manage state: " + link + " is not linked into the service directory (set enabled = :enabled)")
        }
        await_supervision(link)?
        let is_up = running(params)?
        if is_up != (st == "running") {
            let verb = if st == "running" { "up" } else { "down" }
            let out = shell::bash("sv " + verb + " " + q(link), Value::Null)?
            if !out.success { return Err(out.stderr.trim() + out.stdout.trim()) }
        }
    }
    Ok(ApplyResult::Success)
}
