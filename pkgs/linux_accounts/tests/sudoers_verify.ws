use value
use fs
use shell

fn attrs(p: string) -> Result[string, string] {
    Ok(shell::bash("stat -c '%a %u %g' " + p, Value::Null)?.stdout.trim())
}

fn rule(p: string, want: string) -> Result[unit, string] {
    if !fs::is_file(p) { return Err(p + " missing") }
    if fs::read(p)? != want { return Err(p + " holds " + fs::read(p)?) }
    let a = attrs(p)?
    if a != "440 0 0" { return Err(p + " is " + a) }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    rule("/etc/sudoers.d/cwmode", "cwmode ALL=(ALL:ALL) ALL\n")?
    rule("/etc/sudoers.d/john_doe", "john.doe ALL=(ALL:ALL) NOPASSWD: ALL\n")?
    rule("/etc/sudoers.d/%cwadmins", "%cwadmins ALL=(ALL:ALL) /usr/bin/id\n")?
    rule("/etc/sudoers.d/cwnoval", "cwnoval ALL=(ALL:ALL) /usr/bin/id\n")?
    // the rejected update left the live rule alone and no temp file behind
    rule("/etc/sudoers.d/cwkeep", "cwkeep ALL=(ALL:ALL) ALL\n")?
    if fs::exists("/etc/sudoers.d/.cwkeep.cw-tmp") { return Err("temp drop-in left behind") }
    for n in ["cwinject", "cwempty", "john.doe"] {
        if fs::exists("/etc/sudoers.d/" + n) { return Err("/etc/sudoers.d/" + n + " was written") }
    }
    if fs::glob("/etc/sudoers.d/cw *")?.len() > 0 { return Err("a drop-in with a spaced name was written") }
    // the whole sudoers tree still parses
    let chk = shell::bash("visudo -c", Value::Null)?
    if !chk.success { return Err("visudo -c: " + chk.stdout + chk.stderr) }
    Ok(true)
}
