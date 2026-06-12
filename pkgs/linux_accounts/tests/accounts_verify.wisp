use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let user_ok = shell::bash("id -u cwtest >/dev/null 2>&1", Value::Null)?.success
    let key_ok = fs::read("/home/cwtest/.ssh/authorized_keys")?.contains("config-weave")
    Ok(user_ok && key_ok)
}

