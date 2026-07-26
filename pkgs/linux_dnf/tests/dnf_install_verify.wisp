use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // rpm itself, not our check logic, must agree hello is installed.
    Ok(shell::bash("rpm -q hello >/dev/null 2>&1", Value::Null)?.success)
}
