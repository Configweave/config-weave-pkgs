use value
use fs
use shell

fn unit_enabled(name: string) -> Result[bool, string] {
    Ok(shell::bash("systemctl is-enabled --quiet " + name + ".service", Value::Null)?.success)
}

fn unit_active(name: string) -> Result[bool, string] {
    Ok(shell::bash("systemctl is-active --quiet " + name + ".service", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    // systemd itself, not our check logic, must agree on each service.
    if unit_enabled("systemd-timesyncd")? { return Err("systemd-timesyncd still enabled") }
    if unit_active("systemd-timesyncd")? { return Err("systemd-timesyncd still active") }

    if !fs::is_file("/etc/systemd/system/cw-managed.service") { return Err("installed unit file missing") }
    if !unit_enabled("cw-managed")? { return Err("cw-managed not enabled") }
    if !unit_active("cw-managed")? { return Err("cw-managed not running") }

    if fs::exists("/etc/systemd/system/cw-seeded.service") { return Err("removed unit file still present") }
    if unit_enabled("cw-seeded")? { return Err("removed service still enabled") }
    Ok(true)
}
