use value
use fs
use shell

fn sv_status(name: string) -> Result[string, string] {
    let out = shell::bash("sv status /var/service/" + name, Value::Null)?
    if !out.success { return Err("sv status " + name + " failed: " + out.stderr.trim() + out.stdout.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    // runit itself, not our check logic, must agree on each service.
    if !sv_status("cw-stop")?.starts_with("down:") { return Err("cw-stop is not down") }

    if !fs::is_file("/etc/sv/cw-managed/run") { return Err("installed run script missing") }
    if !fs::read_link("/var/service/cw-managed").is_ok() { return Err("cw-managed not linked into the service directory") }
    if !sv_status("cw-managed")?.starts_with("run:") { return Err("cw-managed is not running") }

    if fs::exists("/etc/sv/cw-seeded") { return Err("removed service definition still present") }
    Ok(true)
}
