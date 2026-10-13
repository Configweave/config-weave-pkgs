use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let binary = "/opt/pwsh-7.5.4/pwsh"
    if !fs::is_file(binary) { return Err("the tarball did not produce " + binary) }
    if !fs::exists("/usr/local/bin/pwsh-cwtest") { return Err("the symlink was not created") }
    // The extracted binary must actually run, which proves chmod +x landed.
    let out = shell::run("/usr/local/bin/pwsh-cwtest -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if !out.success { return Err("the extracted pwsh does not run: " + out.stderr.trim()) }
    if out.stdout.trim() != "7.5.4" { return Err("the extracted pwsh reports " + out.stdout.trim() + ", not the pinned 7.5.4") }
    // The extracted root is marked as this resource's own.
    if !fs::is_file("/opt/pwsh-7.5.4/.config-weave-archive") { return Err("the extracted root carries no ownership marker") }
    // The seeded root was removed; the one never installed was not created.
    if fs::exists("/opt/pwsh-7.4.6") { return Err("the seeded tarball root was not removed") }
    if fs::exists("/opt/microsoft/powershell/7.3.12") { return Err("the ensure = :absent step created a root it should have left alone") }
    Ok(true)
}
