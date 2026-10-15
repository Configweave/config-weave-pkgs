use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let tz = shell::bash("test \"$(dpkg-query -W -f='${{db:Status-Status}}' tzdata 2>/dev/null)\" = installed", Value::Null)?
    if tz.success { return Err("tzdata should have been removed") }
    let holds = shell::bash("apt-mark showhold", Value::Null)?
    if !holds.success { return Err(holds.stderr.trim()) }
    if holds.stdout.trim() != "" { return Err("still held: " + holds.stdout.trim().replace("\n", " ")) }
    Ok(true)
}
