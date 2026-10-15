use value
use fs
use shell
use common

fn require_openrc() -> Result[unit, string] {
    if shell::bash("command -v rc-update >/dev/null 2>&1 && command -v rc-service >/dev/null 2>&1", Value::Null)?.success { return Ok(()) }
    Err("rc-update not found; is OpenRC installed?")
}

fn script_path(name: string) -> string { "/etc/init.d/" + name }

// Runlevel membership is a symlink /etc/runlevels/<runlevel>/<name>, which
// is all `rc-update add` creates.
fn link_path(name: string, runlevel: string) -> string { "/etc/runlevels/" + runlevel + "/" + name }

fn in_runlevel(name: string, runlevel: string) -> bool { fs::read_link(link_path(name, runlevel)).is_ok() }

// Every runlevel the service is in (boot, sysinit, default, custom ones).
fn runlevel_links(name: string) -> Result[List[string], string] {
    let out = []
    for l in fs::glob("/etc/runlevels/*/" + name)? {
        if fs::read_link(l).is_ok() { out.push(l) }
    }
    Ok(out)
}

// OpenRC's status codes: 0 started, 3 stopped, 4 stopping, 8 starting,
// 16 inactive, 32 crashed (marked started but its daemon is gone). Only
// meaningful once the init script exists.
fn status(name: string) -> Result[int, string] {
    Ok(shell::bash("rc-service " + common::q(name) + " status >/dev/null 2>&1", Value::Null)?.code)
}

fn rc(name: string, verb: string) -> Result[unit, string] {
    common::run("rc-service " + name + " " + verb, "rc-service " + common::q(name) + " " + verb)
}

fn mtime(p: string) -> int {
    match fs::metadata(p) {
        Ok(m) => {
            if let Some(v) = m.get("modified") { return v.as_int().unwrap_or(0) }
            0
        },
        Err(e) => 0,
    }
}

// The service was started before its script last changed, so it is still
// running the old definition. OpenRC records the start as the symlink
// /run/openrc/started/<name>, whose own mtime is the start time.
fn stale(name: string) -> bool {
    let started = "/run/openrc/started/" + name
    if !fs::read_link(started).is_ok() { return false }
    mtime(script_path(name)) > mtime(started)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    common::require_name("name", name)?
    let runlevel = common::param_str(params, "runlevel", "default")
    common::require_name("runlevel", runlevel)?
    require_openrc()?
    let p = script_path(name)
    if !common::want_present(params)? {
        if fs::lexists(p) { return Ok(CheckResult::NotConfigured) }
        if !runlevel_links(name)?.is_empty() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !fs::is_file(p) { return Ok(CheckResult::NotConfigured) }
    // An empty `script` means "manage the service that is already there",
    // so the content is only drift when content was actually supplied.
    let body = common::param_str(params, "script", "")
    if body != "" && !common::has_content(p, body) { return Ok(CheckResult::NotConfigured) }
    if !common::executable(p)? { return Ok(CheckResult::NotConfigured) }
    let en = common::desired_enabled(params)?
    if en != "unmanaged" && in_runlevel(name, runlevel) != (en == "enabled") {
        return Ok(CheckResult::NotConfigured)
    }
    let st = common::desired_state(params)?
    if st == "running" {
        if status(name)? != 0 { return Ok(CheckResult::NotConfigured) }
        if body != "" && stale(name) { return Ok(CheckResult::NotConfigured) }
    }
    if st == "stopped" && status(name)? != 3 { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    common::require_name("name", name)?
    let runlevel = common::param_str(params, "runlevel", "default")
    common::require_name("runlevel", runlevel)?
    require_openrc()?
    let p = script_path(name)
    if !common::want_present(params)? {
        // Stop while the script still exists: OpenRC cannot stop a service
        // whose script has gone. A crashed service has nothing to stop, so
        // `zap` just clears its started mark.
        if fs::is_file(p) {
            let s = status(name)?
            if s == 32 { rc(name, "zap")? } else if s != 3 { rc(name, "stop")? }
        }
        // Out of every runlevel, not only `runlevel`.
        for l in runlevel_links(name)? { fs::delete(l)? }
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
    if en != "unmanaged" && in_runlevel(name, runlevel) != (en == "enabled") {
        let verb = if en == "enabled" { "add" } else { "del" }
        common::run("rc-update " + verb + " " + name + " " + runlevel, "rc-update " + verb + " " + common::q(name) + " " + common::q(runlevel))?
    }
    let st = common::desired_state(params)?
    if st == "running" {
        let s = status(name)?
        // `start` on a crashed service only warns "already started", so its
        // mark is zapped first.
        if s == 32 {
            rc(name, "zap")?
            rc(name, "start")?
        } else if s == 0 {
            if body != "" && (changed || stale(name)) { rc(name, "restart")? }
        } else {
            rc(name, "start")?
        }
    }
    if st == "stopped" {
        let s = status(name)?
        if s == 32 { rc(name, "zap")? } else if s != 3 { rc(name, "stop")? }
    }
    Ok(ApplyResult::Success)
}
