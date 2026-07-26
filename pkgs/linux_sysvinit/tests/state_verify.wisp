use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // The init script's own `status` must agree the daemon is running.
    Ok(shell::bash("/etc/init.d/cw-daemon status", Value::Null)?.success)
}
