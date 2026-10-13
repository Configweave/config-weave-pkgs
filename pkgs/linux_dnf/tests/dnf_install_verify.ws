use value
use shell

// rpm itself, not our check logic, says what is installed.
fn rpm_q(name: string) -> Result[string, string] {
    let out = shell::bash("rpm -q --qf '%{{VERSION}}-%{{RELEASE}}\\n' " + name + " 2>/dev/null", Value::Null)?
    if !out.success { return Ok("") }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    if rpm_q("tree")? == "" { return Err("tree should be installed") }
    if rpm_q("which")? != "2.23-4.fc44" { return Err("which should be 2.23-4.fc44, rpm says '" + rpm_q("which")? + "'") }
    if rpm_q("dos2unix")? != "" { return Err("dos2unix should be removed") }
    // the guard refused, so both are still there
    if rpm_q("oniguruma")? == "" || rpm_q("jq")? == "" { return Err("oniguruma and jq should both still be installed") }
    Ok(true)
}
