use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // apk itself, not our check logic, must agree tree is installed.
    Ok(shell::bash("apk info -e tree >/dev/null 2>&1", Value::Null)?.success)
}
