use value
use fs
use shell

fn sh(cmd: string) -> Result[string, string] {
    Ok(shell::bash(cmd, Value::Null)?.stdout.trim())
}

fn enablement(name: string) -> Result[string, string] { sh("systemctl is-enabled " + name + ".service") }

fn unit_active(name: string) -> Result[bool, string] {
    Ok(shell::bash("systemctl is-active --quiet " + name + ".service", Value::Null)?.success)
}

fn main_pid(name: string) -> Result[string, string] { sh("systemctl show -p MainPID --value " + name + ".service") }

// Every failed expectation, so one run shows them all.
fn problems() -> Result[List[string], string] {
    let errs = []
    // systemd itself, not our check logic, must agree on each service.
    if enablement("systemd-timesyncd")? == "enabled" { errs.push("systemd-timesyncd still enabled") }
    if unit_active("systemd-timesyncd")? { errs.push("systemd-timesyncd still active") }

    if !fs::is_file("/etc/systemd/system/cw-managed.service") { errs.push("installed unit file missing") }
    if enablement("cw-managed")? != "enabled" { errs.push("cw-managed not enabled") }
    if !unit_active("cw-managed")? { errs.push("cw-managed not running") }

    if !fs::is_file("/etc/systemd/system/cw-suffix.service") { errs.push("cw-suffix.service missing") }
    if fs::exists("/etc/systemd/system/cw-suffix.service.service") { errs.push("cw-suffix got a doubled .service suffix") }
    if enablement("cw-suffix")? != "enabled" { errs.push("cw-suffix not enabled") }

    if fs::exists("/etc/systemd/system/cw-seeded.service") { errs.push("removed unit file still present") }
    if enablement("cw-seeded")? == "enabled" { errs.push("removed service still enabled") }
    let seeded = fs::read("/run/cw-seeded.seeded")?.trim()
    if shell::bash("kill -0 " + seeded, Value::Null)?.success { errs.push("cw-seeded's process (pid " + seeded + ") is still running") }

    if enablement("cw-stop")? != "disabled" { errs.push("cw-stop is " + enablement("cw-stop")? + ", not disabled") }
    if unit_active("cw-stop")? { errs.push("cw-stop still active") }

    let pid = main_pid("cw-change")?
    let cmdline = sh("tr '\\0' ' ' < /proc/" + pid + "/cmdline")?
    if !cmdline.contains("7200") { errs.push("cw-change still runs the old unit: " + cmdline) }

    if main_pid("cw-stale")? == fs::read("/run/cw-stale.seeded")?.trim() { errs.push("cw-stale was not restarted") }
    if !unit_active("cw-stale")? { errs.push("cw-stale not running") }

    if enablement("cw-static")? != "static" { errs.push("cw-static is no longer static") }

    if unit_active("cw-vstatic")? { errs.push("cw-vstatic still active") }
    if !fs::is_file("/usr/lib/systemd/system/cw-vstatic.service") { errs.push("removing cw-vstatic deleted its vendor unit") }

    if !sh("systemctl show -p Environment --value cw-dropin.service")?.contains("CW_DROPIN=1") { errs.push("cw-dropin's drop-in was not loaded") }

    if fs::exists("/etc/systemd/system/cw-old.timer") { errs.push("cw-old.timer still present") }
    if sh("systemctl show -p LoadState --value cw-old.timer")? == "loaded" { errs.push("systemd still has cw-old.timer loaded") }
    Ok(errs)
}

fn verify(facts: Value) -> Result[bool, string] {
    let errs = problems()?
    if !errs.is_empty() { return Err(errs.join("; ")) }
    Ok(true)
}
