use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // pacman itself, not our check logic, must agree tree is installed.
    Ok(shell::bash("pacman -Q tree >/dev/null 2>&1", Value::Null)?.success)
}
