use value
use shell

// pacman itself, not our check logic, says what is installed.
fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("pacman -Q " + name + " >/dev/null 2>&1", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    if !installed("which")? { return Err("which should be installed") }
    if installed("tree")? { return Err("tree should be removed") }
    Ok(true)
}
