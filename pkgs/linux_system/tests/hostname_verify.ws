use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    if fs::read("/etc/hostname")? != "cw-test-host\n" { return Err("/etc/hostname not converged") }
    let running = fs::read("/proc/sys/kernel/hostname")?.trim()
    if running != "cw-test-host" { return Err("running hostname is " + running) }
    Ok(true)
}
