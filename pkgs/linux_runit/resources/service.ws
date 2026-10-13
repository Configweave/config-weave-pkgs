use value
use fs
use path
use shell
use time
use common

fn require_sv() -> Result[unit, string] {
    if shell::bash("command -v sv >/dev/null 2>&1", Value::Null)?.success { return Ok(()) }
    Err("sv not found; is runit installed?")
}

fn validate(params: Value) -> Result[unit, string] {
    common::require_name(common::param_str(params, "name", ""))?
    common::require_dir("sv_dir", common::param_str(params, "sv_dir", "/etc/sv"))?
    common::require_dir("service_dir", common::param_str(params, "service_dir", "/var/service"))?
    Ok(())
}

// A runit service is a directory holding an executable `run` script; it is
// activated by symlinking that directory into the supervised service dir.
fn sv_path(params: Value) -> string {
    common::param_str(params, "sv_dir", "/etc/sv") + "/" + common::param_str(params, "name", "")
}

fn run_path(params: Value) -> string { sv_path(params) + "/run" }

// runsv leaves a service with a `down` file down when it starts
// supervising it, so `:stopped` survives runsv restarts and reboots.
fn down_path(params: Value) -> string { sv_path(params) + "/down" }

fn link_path(params: Value) -> string {
    common::param_str(params, "service_dir", "/var/service") + "/" + common::param_str(params, "name", "")
}

// "linked" when the link points at sv_path, "wrong" when it points
// anywhere else, "missing" when there is nothing there. Anything else at
// the link path is not this resource's to replace.
fn link_state(params: Value) -> Result[string, string] {
    let link = link_path(params)
    match fs::read_link(link) {
        Ok(t) => {
            let target = if t.starts_with("/") { t } else { path::parent(link) + "/" + t }
            if path::normalize(target) == path::normalize(sv_path(params)) { Ok("linked") } else { Ok("wrong") }
        },
        Err(e) => {
            if fs::exists(link) { return Err(link + " exists and is not a symlink; refusing to manage it") }
            Ok("missing")
        },
    }
}

// `sv status` on a directory no runsv is supervising fails.
fn supervised(dir: string) -> Result[bool, string] {
    Ok(shell::bash("sv status " + common::q(dir) + " >/dev/null 2>&1", Value::Null)?.success)
}

// runsvdir rescans its directory every few seconds, so a freshly linked
// service is not supervised the instant the symlink appears. Wait for runsv
// to claim it.
fn await_supervision(link: string) -> Result[unit, string] {
    for i in 0..60 {
        if supervised(link)? { return Ok(()) }
        time::sleep(500)
    }
    Err("timed out waiting for runsvdir to supervise " + link)
}

// Status lines look like "run: /var/service/x: (pid 813) 5s[, normally
// down]". Only meaningful while the service is supervised.
fn status_line(params: Value) -> Result[string, string] {
    let out = shell::bash("sv status " + common::q(link_path(params)), Value::Null)?
    if !out.success { return Ok("") }
    Ok(out.stdout.trim())
}

fn running(params: Value) -> Result[bool, string] { Ok(status_line(params)?.starts_with("run:")) }

// Seconds the service has been up, from its status line.
fn uptime(line: string) -> int {
    let rest = line.split(") ").get(1).unwrap_or("")
    let secs = 0
    for c in rest.chars() {
        if c < '0' || c > '9' { break }
        secs = secs * 10 + (int(c) - int('0'))
    }
    secs
}

// The service was started before its run script last changed, so it is
// still running the old one. The start time comes from the uptime in whole
// seconds, so a second of slack keeps a restart in the same second as the
// write from counting as stale.
fn stale(params: Value) -> Result[bool, string] {
    let line = status_line(params)?
    if !line.starts_with("run:") { return Ok(false) }
    let started = int(time::now_unix()) - uptime(line)
    Ok(common::mtime(run_path(params)) > started + 1)
}

fn sv(verb: string, target: string) -> Result[unit, string] {
    common::run("sv " + verb + " " + target, "sv -v -w 30 " + verb + " " + common::q(target))
}

// `sv -v restart` can report success on the "down, want up" status that
// follows the TERM, and runsv waits a second before restarting a service
// that ran for less than one. Wait until it is really running.
fn await_running(params: Value) -> Result[unit, string] {
    for i in 0..60 {
        if running(params)? { return Ok(()) }
        time::sleep(500)
    }
    Err("timed out waiting for " + link_path(params) + " to come up: " + status_line(params)?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    require_sv()?
    let ls = link_state(params)?
    if !common::want_present(params)? {
        if ls != "missing" { return Ok(CheckResult::NotConfigured) }
        if fs::exists(sv_path(params)) { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let rp = run_path(params)
    if !fs::is_file(rp) { return Ok(CheckResult::NotConfigured) }
    // An empty `run` means "manage the service definition that is already
    // there", so content is only drift when content was actually supplied.
    let body = common::param_str(params, "run", "")
    if body != "" && !common::has_content(rp, body) { return Ok(CheckResult::NotConfigured) }
    if !common::executable(rp)? { return Ok(CheckResult::NotConfigured) }
    let en = common::desired_enabled(params)?
    if en != "unmanaged" && (ls == "linked") != (en == "enabled") {
        return Ok(CheckResult::NotConfigured)
    }
    let st = common::desired_state(params)?
    if st == "unmanaged" { return Ok(CheckResult::AlreadyConfigured) }
    if (st == "stopped") != fs::exists(down_path(params)) { return Ok(CheckResult::NotConfigured) }
    // Once apply has run, the service is linked exactly when this is true.
    let will_link = en == "enabled" || (en == "unmanaged" && ls == "linked")
    if !will_link {
        // Nothing supervises an unlinked service, so it cannot be running;
        // the down file alone is :stopped.
        if st == "running" { return Err("cannot manage state = :running: " + link_path(params) + " is not linked into the service directory (set enabled = :enabled)") }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if ls != "linked" { return Ok(CheckResult::NotConfigured) }
    if running(params)? != (st == "running") { return Ok(CheckResult::NotConfigured) }
    if st == "running" && body != "" && stale(params)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    validate(params)?
    require_sv()?
    let link = link_path(params)
    let dir = sv_path(params)
    let ls = link_state(params)?
    if !common::want_present(params)? {
        // Stop the service, then unlink it so runsvdir does not start a new
        // runsv, then tell the runsv still holding the definition to exit
        // and wait for it before deleting the directory under it.
        if ls != "missing" {
            if supervised(link)? { sv("down", link)? }
            fs::delete(link)?
        }
        if fs::exists(dir) {
            if fs::is_dir(dir + "/log") && supervised(dir + "/log")? { sv("exit", dir + "/log")? }
            if supervised(dir)? {
                sv("exit", dir)?
                let gone = false
                for i in 0..60 {
                    if !supervised(dir)? {
                        gone = true
                        break
                    }
                    time::sleep(500)
                }
                if !gone { return Err("timed out waiting for runsv to release " + dir) }
            }
            fs::delete_dir(dir)?
        }
        return Ok(ApplyResult::Success)
    }
    let rp = run_path(params)
    let body = common::param_str(params, "run", "")
    // Only a process already running before the write runs the old script;
    // one runsv starts after it (a fresh link) runs the new one.
    let was_up = ls == "linked" && running(params)?
    let changed = false
    if body != "" {
        if !common::has_content(rp, body) {
            fs::mkdir(dir)?
            fs::write(rp, body)?
            changed = true
        }
    } else if !fs::is_file(rp) {
        return Err("no run script at " + rp + " and no 'run' content was given")
    }
    if !common::executable(rp)? { common::make_executable(rp)? }
    let en = common::desired_enabled(params)?
    let st = common::desired_state(params)?
    let will_link = en == "enabled" || (en == "unmanaged" && ls == "linked")
    if st == "running" && !will_link {
        return Err("cannot manage state = :running: " + link + " is not linked into the service directory (set enabled = :enabled)")
    }
    // The down file goes in before the link, so enabling a :stopped
    // service never starts it.
    if st == "stopped" && !fs::exists(down_path(params)) { fs::write(down_path(params), "")? }
    if st == "running" && fs::exists(down_path(params)) { fs::delete(down_path(params))? }
    if en == "enabled" && ls != "linked" {
        if ls == "wrong" { fs::delete(link)? }
        fs::mkdir(path::parent(link))?
        fs::symlink(dir, link)?
    }
    if en == "disabled" && ls != "missing" { fs::delete(link)? }
    if st == "unmanaged" || !will_link { return Ok(ApplyResult::Success) }
    await_supervision(link)?
    let is_up = running(params)?
    if st == "running" {
        if !is_up {
            sv("up", link)?
        } else if body != "" && ((changed && was_up) || stale(params)?) {
            sv("restart", link)?
        }
        await_running(params)?
    } else if is_up {
        sv("down", link)?
    }
    Ok(ApplyResult::Success)
}
