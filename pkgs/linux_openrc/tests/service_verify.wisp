use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // crond must be in the default runlevel and actually running — the two
    // resources under test, observed through OpenRC rather than our own
    // check logic.
    let listed = shell::bash("rc-update show default | grep -q crond", Value::Null)?
    let running = shell::bash("rc-service crond status >/dev/null 2>&1", Value::Null)?
    Ok(listed.success && running.success)
}
