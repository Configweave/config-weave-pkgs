use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // dpkg itself, not our check logic, must agree hello is installed.
    Ok(shell::bash("dpkg -s hello >/dev/null 2>&1", Value::Null)?.success)
}
