use value
use fs
use shell
use common

fn has_update_rcd() -> bool { fs::exists("/usr/sbin/update-rc.d") || fs::exists("/sbin/update-rc.d") }
fn has_chkconfig() -> bool { fs::exists("/sbin/chkconfig") || fs::exists("/usr/sbin/chkconfig") }

fn script_path(name: string) -> string { "/etc/init.d/" + name }

// Enabled means a start symlink exists in any runlevel directory.
fn start_links(name: string) -> Result[bool, string] {
    let matches = fs::glob("/etc/rc?.d/S??" + name)?
    Ok(!matches.is_empty())
}

// The init script's own `status` verb is the only portable probe.
fn running(name: string) -> Result[bool, string] {
    Ok(shell::bash("/etc/init.d/" + common::q(name) + " status >/dev/null 2>&1", Value::Null)?.success)
}

fn set_enabled(name: string, want: bool) -> Result[unit, string] {
    if has_update_rcd() {
        let cmd = if want { "update-rc.d " + common::q(name) + " defaults" } else { "update-rc.d -f " + common::q(name) + " remove" }
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(())
    }
    if has_chkconfig() {
        let cmd = "chkconfig " + common::q(name) + (if want { " on" } else { " off" })
        let out = shell::bash(cmd, Value::Null)?
        if !out.success { return Err(out.stderr.trim()) }
        return Ok(())
    }
    Err("neither update-rc.d nor chkconfig found")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = script_path(name)
    if !common::want_present(params)? {
        if fs::exists(p) { return Ok(CheckResult::NotConfigured) }
        if start_links(name)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    // An empty `script` means "manage the script that is already there", so
    // the content is only drift when content was actually supplied.
    let script = common::param_str(params, "script", "")
    if script != "" && fs::read(p)? != script { return Ok(CheckResult::NotConfigured) }
    let en = common::desired_enabled(params)?
    if en != "unmanaged" && start_links(name)? != (en == "enabled") {
        return Ok(CheckResult::NotConfigured)
    }
    let st = common::desired_state(params)?
    if st != "unmanaged" && running(name)? != (st == "running") {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let p = script_path(name)
    if !common::want_present(params)? {
        // Stop before removing the rc.d links, and remove them before the
        // script: update-rc.d and the `stop` verb both need the script.
        if fs::is_file(p) && running(name)? {
            let out = shell::bash("/etc/init.d/" + common::q(name) + " stop", Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
        if start_links(name)? { set_enabled(name, false)? }
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
        let is_on = start_links(name)?
        if is_on != (en == "enabled") { set_enabled(name, en == "enabled")? }
    }
    let st = common::desired_state(params)?
    if st != "unmanaged" {
        let is_up = running(name)?
        if is_up != (st == "running") {
            let verb = if st == "running" { "start" } else { "stop" }
            let out = shell::bash("/etc/init.d/" + common::q(name) + " " + verb, Value::Null)?
            if !out.success { return Err(out.stderr.trim()) }
        }
    }
    Ok(ApplyResult::Success)
}
