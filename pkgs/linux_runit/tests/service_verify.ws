use value
use fs
use shell

fn sv_status(name: string) -> Result[string, string] {
    let out = shell::bash("sv status /var/service/" + name, Value::Null)?
    if !out.success { return Ok("fail: " + out.stderr.trim() + out.stdout.trim()) }
    Ok(out.stdout.trim())
}

fn pid(name: string) -> Result[string, string] {
    let s = sv_status(name)?
    Ok(s.split("(pid ").get(1).unwrap_or("").split(")").get(0).unwrap_or(""))
}

fn alive(pid: string) -> Result[bool, string] {
    Ok(shell::bash("kill -0 " + pid, Value::Null)?.success)
}

// Every failed expectation, so one run shows them all.
fn problems() -> Result[List[string], string] {
    let errs = []
    // runit itself, not our check logic, must agree on each service.
    if !sv_status("cw-stop")?.starts_with("down:") { errs.push("cw-stop is not down") }
    if !fs::exists("/etc/sv/cw-stop/down") { errs.push("cw-stop has no down file, so it comes back up with runsv") }

    if !fs::is_file("/etc/sv/cw-managed/run") { errs.push("installed run script missing") }
    if fs::read_link("/var/service/cw-managed").unwrap_or("") != "/etc/sv/cw-managed" { errs.push("cw-managed not linked into the service directory") }
    if !sv_status("cw-managed")?.starts_with("run:") { errs.push("cw-managed is not running") }

    if fs::exists("/etc/sv/cw-seeded") { errs.push("removed service definition still present") }

    if fs::exists("/etc/sv/cw-gone") { errs.push("cw-gone definition still present") }
    if fs::read_link("/var/service/cw-gone").is_ok() { errs.push("cw-gone still linked") }
    let gone = fs::read("/run/cw-gone.seeded")?.trim()
    if alive(gone)? { errs.push("cw-gone's process (pid " + gone + ") is still running") }
    if shell::bash("ps | grep -v grep | grep -q 'runsv cw-gone'", Value::Null)?.success { errs.push("runsv cw-gone is still running") }

    if !sv_status("cw-change")?.starts_with("run:") { errs.push("cw-change is not running") }
    if fs::read("/run/cw-change.args")?.trim() != "7200" { errs.push("cw-change still runs the old run script") }

    let stale = fs::read("/run/cw-stale.seeded")?.trim()
    if pid("cw-stale")? == stale { errs.push("cw-stale was not restarted") }

    if fs::read_link("/var/service/cw-wrong").unwrap_or("") != "/etc/sv/cw-wrong" { errs.push("cw-wrong still points elsewhere") }

    if !shell::bash("test -x /etc/sv/cw-noexec/run", Value::Null)?.success { errs.push("cw-noexec run script is not executable") }

    if fs::read_link("/var/service/cw-dstop").unwrap_or("") != "/etc/sv/cw-dstop" { errs.push("cw-dstop not linked") }
    if !sv_status("cw-dstop")?.starts_with("down:") { errs.push("cw-dstop is not down") }
    if fs::exists("/run/cw-dstop.args") { errs.push("cw-dstop was started before it was stopped") }

    if !fs::exists("/etc/sv/cw-ustop/down") { errs.push("cw-ustop has no down file") }
    if fs::read_link("/var/service/cw-ustop").is_ok() { errs.push("cw-ustop was linked") }

    if fs::read_link("/var/service/cw-dis").is_ok() { errs.push("cw-dis still linked") }
    if !fs::is_file("/etc/sv/cw-dis/run") { errs.push("disabling deleted cw-dis's definition") }

    if !fs::is_dir("/var/service/cw-realdir") || fs::read_link("/var/service/cw-realdir").is_ok() { errs.push("cw-realdir's directory was replaced") }
    Ok(errs)
}

fn verify(facts: Value) -> Result[bool, string] {
    let errs = problems()?
    if !errs.is_empty() { return Err(errs.join("; ")) }
    Ok(true)
}
