use value
use fs
use shell
use common

fn has_update_rcd() -> bool { fs::exists("/usr/sbin/update-rc.d") || fs::exists("/sbin/update-rc.d") }
fn has_chkconfig() -> bool { fs::exists("/sbin/chkconfig") || fs::exists("/usr/sbin/chkconfig") }

fn script_path(name: string) -> string { "/etc/init.d/" + name }

// rc.d links for the service whose names start with one of `kinds` ("S",
// or "[SK]" for start and kill links alike). `require_name` keeps glob
// metacharacters out of `name`.
fn links(name: string, kinds: string) -> Result[List[string], string] {
    fs::glob("/etc/rc?.d/" + kinds + "??" + name)
}

// Enabled means a start link exists in some runlevel directory. A disabled
// service may still have kill links: those stop it at shutdown.
fn start_links(name: string) -> Result[bool, string] { Ok(!links(name, "S")?.is_empty()) }

fn any_links(name: string) -> Result[bool, string] { Ok(!links(name, "[SK]")?.is_empty()) }

// The init script's own `status` verb is the only portable probe.
fn running(name: string) -> Result[bool, string] {
    Ok(shell::bash(common::q(script_path(name)) + " status >/dev/null 2>&1", Value::Null)?.success)
}

fn script(name: string, verb: string) -> Result[unit, string] {
    common::run(script_path(name) + " " + verb, common::q(script_path(name)) + " " + verb)
}

// Debian's update-rc.d: `defaults` creates links only when the service has
// none, so a service someone disabled (kill links only) needs `enable`.
// chkconfig: `--add` registers the script, `on` turns its start links on.
fn enable(name: string) -> Result[unit, string] {
    let qn = common::q(name)
    if has_update_rcd() {
        common::run("update-rc.d " + name + " defaults", "update-rc.d " + qn + " defaults")?
        if !start_links(name)? { common::run("update-rc.d " + name + " enable", "update-rc.d " + qn + " enable")? }
    } else if has_chkconfig() {
        common::run("chkconfig --add " + name, "chkconfig --add " + qn)?
        common::run("chkconfig " + name + " on", "chkconfig " + qn + " on")?
    } else {
        return Err("neither update-rc.d nor chkconfig found")
    }
    if !start_links(name)? {
        return Err("enabling " + name + " created no start links: the script's LSB header has an empty Default-Start")
    }
    Ok(())
}

// Disabling turns the start links into kill links, as both tools do, so
// the service is still stopped at shutdown.
fn disable(name: string) -> Result[unit, string] {
    let qn = common::q(name)
    if has_update_rcd() { return common::run("update-rc.d " + name + " disable", "update-rc.d " + qn + " disable") }
    if has_chkconfig() { return common::run("chkconfig " + name + " off", "chkconfig " + qn + " off") }
    Err("neither update-rc.d nor chkconfig found")
}

// Every start and kill link goes. The tools need the script, so they run
// first while it exists; whatever links remain after them (or when the
// script is already gone) are deleted directly.
fn remove_links(name: string) -> Result[unit, string] {
    let qn = common::q(name)
    if fs::is_file(script_path(name)) {
        if has_update_rcd() {
            common::run("update-rc.d -f " + name + " remove", "update-rc.d -f " + qn + " remove")?
        } else if has_chkconfig() {
            common::run("chkconfig --del " + name, "chkconfig --del " + qn)?
        }
    }
    for l in links(name, "[SK]")? { fs::delete(l)? }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::require_name(name)?
    let p = script_path(name)
    if !common::want_present(params)? {
        if fs::lexists(p) { return Ok(CheckResult::NotConfigured) }
        if any_links(name)? { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    // An empty `script` means "manage the script that is already there", so
    // the content is only drift when content was actually supplied.
    let body = common::param_str(params, "script", "")
    if body != "" && !common::has_content(p, body) { return Ok(CheckResult::NotConfigured) }
    if !common::executable(p)? { return Ok(CheckResult::NotConfigured) }
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
    common::require_name(name)?
    let p = script_path(name)
    if !common::want_present(params)? {
        // Stop before removing the rc.d links, and remove them before the
        // script: update-rc.d, chkconfig and the `stop` verb need it.
        if fs::is_file(p) && running(name)? { script(name, "stop")? }
        remove_links(name)?
        if fs::lexists(p) { fs::delete(p)? }
        return Ok(ApplyResult::Success)
    }
    let body = common::param_str(params, "script", "")
    let changed = false
    if body != "" {
        if !common::has_content(p, body) {
            fs::write(p, body)?
            changed = true
        }
    } else if !fs::is_file(p) {
        return Err("no init script at " + p + " and no 'script' content was given")
    }
    if !common::executable(p)? { common::make_executable(p)? }
    let en = common::desired_enabled(params)?
    if en != "unmanaged" && start_links(name)? != (en == "enabled") {
        if en == "enabled" { enable(name)? } else { disable(name)? }
    }
    let st = common::desired_state(params)?
    if st != "unmanaged" {
        let is_up = running(name)?
        if st == "running" && is_up && changed {
            // The daemon was started from the old script.
            script(name, "restart")?
        } else if is_up != (st == "running") {
            script(name, if st == "running" { "start" } else { "stop" })?
        }
    }
    Ok(ApplyResult::Success)
}
