use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let tz = shell::bash("test \"$(dpkg-query -W -f='${db:Status-Status}' tzdata 2>/dev/null)\" = installed", Value::Null)?
    if tz.success { return Err("tzdata should have been removed") }
    let holds = shell::bash("apt-mark showhold", Value::Null)?
    if !holds.success { return Err(holds.stderr.trim()) }
    let held = holds.stdout
    if !held.contains("base-files") { return Err("base-files should be held") }
    if held.contains("gzip") { return Err("gzip should have been unheld") }
    let dc = shell::bash("printf 'get cw-test/enable\\n' | debconf-communicate cw-test", Value::Null)?
    if !dc.success || dc.stdout.trim() != "0 true" { return Err("debconf answer not set: " + dc.stdout.trim()) }
    Ok(true)
}
