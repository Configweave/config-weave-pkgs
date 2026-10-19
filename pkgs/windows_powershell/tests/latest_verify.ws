use value
use common
use shell

// The release the resource should have resolved, read the same way.
fn verify(facts: Value) -> Result[bool, string] {
    let want = common::latest_release("stable", "")?
    let out = shell::run("/opt/pwsh-latest/pwsh -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if !out.success { return Err("the extracted pwsh does not run: " + out.stderr.trim()) }
    if out.stdout.trim() != want { return Err("/opt/pwsh-latest/pwsh reports " + out.stdout.trim() + ", not the latest release " + want) }
    Ok(true)
}
