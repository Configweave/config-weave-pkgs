use value
use fs
use shell
use common

fn has_systemctl() -> bool { fs::exists("/bin/systemctl") || fs::exists("/usr/bin/systemctl") }

// This resource owns .service units only; `unit_file` covers timers,
// sockets and every other unit type.
fn unit_name(name: string) -> string { name + ".service" }

fn unit_path(name: string) -> string { "/etc/systemd/system/" + unit_name(name) }

fn enabled(name: string) -> Result[bool, string] {
    Ok(shell::bash("systemctl is-enabled --quiet " + common::q(unit_name(name)), Value::Null)?.success)
}

fn active(name: string) -> Result[bool, string] {
    Ok(shell::bash("systemctl is-active --quiet " + common::q(unit_name(name)), Value::Null)?.success)
}

fn daemon_reload() -> Result[unit, string] {
    let out = shell::run("systemctl daemon-reload", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !has_systemctl() { return Err("systemctl is not available on this host") }
    let p = unit_path(name)
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        if enabled(name)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // An empty `unit` means "manage a unit that already exists" — which
    // includes vendor units under /lib, so the file under /etc is only
    // required when this resource is the one writing it.
    let body = common::param_str(params, "unit", "")
    if body != "" {
        if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
        if fs::read(p)? != body { return Ok(CheckResult::NotConfigured) }
    }
    let en = common::desired_enabled(params)?
    if en != "unmanaged" && enabled(name)? != (en == "enabled") {
        return Ok(CheckResult::NotConfigured)
    }
    let st = common::desired_state(params)?
    if st != "unmanaged" && active(name)? != (st == "running") {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !has_systemctl() { return Err("systemctl is not available on this host") }
    let p = unit_path(name)
    let qn = common::q(unit_name(name))
    if !common::want_present(params)? {
        // Stop and disable while the unit file is still there — systemd
        // cannot resolve a unit it can no longer read.
        if active(name)? {
            let out = shell::bash("systemctl stop " + qn, Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
        if enabled(name)? {
            let out = shell::bash("systemctl disable " + qn, Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
        if fs::exists(p) {
            fs::delete(p)?
            daemon_reload()?
        }
        return Ok(ApplyResult::Success)
    }
    let body = common::param_str(params, "unit", "")
    if body != "" {
        fs::write(p, body)?
        // The unit must be re-read before enable/start act on the new file.
        daemon_reload()?
    }
    let en = common::desired_enabled(params)?
    if en != "unmanaged" {
        let is_on = enabled(name)?
        if is_on != (en == "enabled") {
            let verb = if en == "enabled" { "enable" } else { "disable" }
            let out = shell::bash("systemctl " + verb + " " + qn, Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
    }
    let st = common::desired_state(params)?
    if st != "unmanaged" {
        let is_up = active(name)?
        if is_up != (st == "running") {
            let verb = if st == "running" { "start" } else { "stop" }
            let out = shell::bash("systemctl " + verb + " " + qn, Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
    }
    Ok(ApplyResult::Success)
}
