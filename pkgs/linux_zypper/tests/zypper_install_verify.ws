use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    if !shell::bash("rpm -q hello >/dev/null 2>&1", Value::Null)?.success { return Err("hello should be installed") }
    let tz = shell::bash("rpm -q --qf '%{{VERSION}}' timezone", Value::Null)?
    if tz.stdout.trim() != "2024a" { return Err("timezone should be 2024a, rpm says '" + tz.stdout.trim() + "'") }
    Ok(true)
}
