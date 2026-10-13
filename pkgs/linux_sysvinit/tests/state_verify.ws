use value
use fs
use shell

fn up(name: string) -> Result[bool, string] {
    Ok(shell::bash("/etc/init.d/" + name + " status", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    // The init scripts' own `status` must agree with each step.
    if !up("cw-daemon")? { return Err("cw-daemon is not running") }
    if up("cw-stopme")? { return Err("cw-stopme is still running") }
    if !up("cw-change")? { return Err("cw-change is not running") }
    // Restarted, so the running daemon came from the new script.
    if fs::read("/run/cw-change.ver")?.trim() != "v2" { return Err("cw-change was not restarted from the new script") }
    if !shell::bash("test -x /etc/init.d/cw-noexec", Value::Null)?.success { return Err("cw-noexec is not executable") }
    Ok(true)
}
