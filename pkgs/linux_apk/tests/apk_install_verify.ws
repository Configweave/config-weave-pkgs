use value
use fs
use shell

fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("apk info -e " + name + " >/dev/null 2>&1", Value::Null)?.success)
}

fn in_world(spec: string) -> Result[bool, string] {
    for l in fs::read("/etc/apk/world")?.split("\n") { if l.trim() == spec { return Ok(true) } }
    Ok(false)
}

fn verify(facts: Value) -> Result[bool, string] {
    // apk itself, not our check logic, must agree.
    if !installed("tree")? || !in_world("tree")? { return Err("tree should be installed and in world") }
    if !in_world("xz>=5")? { return Err("world should hold the constraint xz>=5") }
    if in_world("xz")? { return Err("the unconstrained xz entry should have been replaced") }
    Ok(true)
}
