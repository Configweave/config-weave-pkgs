use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // The pin installed the pinned version, not the repository's newest, and
    // the refused tarball install left the package's tree working.
    let out = shell::run("/opt/microsoft/powershell/7/pwsh -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if !out.success { return Err("the packaged pwsh does not run: " + out.stderr.trim()) }
    if out.stdout.trim() != "7.4.6" { return Err("the repository install reports " + out.stdout.trim() + ", not the pinned 7.4.6") }
    let dpkg = shell::run("dpkg-query -W -f=${{Version}} powershell", Value::Null)?
    if !dpkg.stdout.starts_with("7.4.6") { return Err("dpkg reports powershell " + dpkg.stdout) }
    Ok(true)
}
