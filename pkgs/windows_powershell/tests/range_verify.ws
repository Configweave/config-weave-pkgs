use value
use shell
use version

// The range step must have installed the newest 7.4 release, not the first
// one that matched: newer than 7.4.6, which every mirror of the 7.4 line has
// long since passed.
fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::run("/opt/pwsh-range/pwsh -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if !out.success { return Err("the extracted pwsh does not run: " + out.stderr.trim()) }
    let have = out.stdout.trim()
    if !version::matches(have, "~7.4")? { return Err("/opt/pwsh-range/pwsh reports " + have + ", which is not a 7.4 release") }
    if version::compare(have, "7.4.6")? <= 0 { return Err("/opt/pwsh-range/pwsh reports " + have + ", not the newest 7.4 release") }
    Ok(true)
}
