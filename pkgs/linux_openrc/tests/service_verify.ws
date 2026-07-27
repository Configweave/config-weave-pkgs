use value
use fs
use shell

// `rc-update show` pads the columns (" crond | default"), so the service
// name is stripped of spaces before the exact-match test.
fn in_default(name: string) -> Result[bool, string] {
    Ok(shell::bash("rc-update show default | awk -F'|' '{{gsub(/ /, \"\", $1); print $1}}' | grep -Fxq " + name, Value::Null)?.success)
}

fn running(name: string) -> Result[bool, string] {
    Ok(shell::bash("rc-service " + name + " status >/dev/null 2>&1", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    // OpenRC itself, not our check logic, must agree on all three services.
    if !in_default("crond")? { return Err("crond not in the default runlevel") }
    if !running("crond")? { return Err("crond not running") }

    if !fs::is_file("/etc/init.d/cw-managed") { return Err("installed init script missing") }
    if !in_default("cw-managed")? { return Err("cw-managed not in the default runlevel") }
    if !running("cw-managed")? { return Err("cw-managed not running") }

    if fs::exists("/etc/init.d/cw-seeded") { return Err("removed init script still present") }
    if in_default("cw-seeded")? { return Err("removed service still in the default runlevel") }
    Ok(true)
}
