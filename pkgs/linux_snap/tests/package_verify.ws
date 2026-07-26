use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // snapd itself, not our check logic, must agree the snap is installed.
    Ok(shell::bash("snap list hello-world >/dev/null 2>&1", Value::Null)?.success)
}
