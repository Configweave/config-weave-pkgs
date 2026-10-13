use value
use fs
use shell

fn status(name: string) -> Result[int, string] {
    Ok(shell::bash("rc-service " + name + " status >/dev/null 2>&1", Value::Null)?.code)
}

// Every failed expectation, so one run shows them all.
fn problems() -> Result[List[string], string] {
    let errs = []
    // OpenRC's own status codes: 0 started, 3 stopped, 32 crashed.
    let s = status("cw-crash")?
    if s != 0 { errs.push("cw-crash is not started (status " + str(s) + ")") }
    s = status("cw-crashstop")?
    if s != 3 { errs.push("cw-crashstop is not stopped (status " + str(s) + ")") }
    if status("cw-stopme")? != 3 { errs.push("cw-stopme is not stopped") }

    if status("cw-change")? != 0 {
        errs.push("cw-change is not started")
    } else {
        let pid = fs::read("/run/cw-change.pid")?.trim()
        let cmdline = fs::read("/proc/" + pid + "/cmdline")?.replace("\u{0}", " ")
        if !cmdline.contains("7200") { errs.push("cw-change still runs the old script: " + cmdline) }
    }

    let stale = fs::read("/run/cw-stale.seeded")?.trim()
    if status("cw-stale")? != 0 || fs::read("/run/cw-stale.pid")?.trim() == stale { errs.push("cw-stale was not restarted") }

    if !shell::bash("test -x /etc/init.d/cw-noexec", Value::Null)?.success { errs.push("cw-noexec is not executable") }

    if fs::read_link("/etc/runlevels/default/cw-dis").is_ok() { errs.push("cw-dis still in the default runlevel") }
    if !fs::is_file("/etc/init.d/cw-dis") { errs.push("disabling deleted cw-dis's script") }

    if fs::exists("/etc/init.d/cw-gone") { errs.push("cw-gone script still present") }
    for l in fs::glob("/etc/runlevels/*/cw-gone")? { errs.push("cw-gone still linked at " + l) }
    let gone = fs::read("/run/cw-gone.seeded")?.trim()
    if shell::bash("kill -0 " + gone, Value::Null)?.success { errs.push("cw-gone's daemon (pid " + gone + ") is still running") }
    Ok(errs)
}

fn verify(facts: Value) -> Result[bool, string] {
    let errs = problems()?
    if !errs.is_empty() { return Err(errs.join("; ")) }
    Ok(true)
}
