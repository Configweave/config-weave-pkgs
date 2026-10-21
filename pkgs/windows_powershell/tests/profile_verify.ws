use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let host_profile = "/cwhome/.config/powershell/Microsoft.PowerShell_profile.ps1"
    let all_hosts = "/cwhome/.config/powershell/profile.ps1"

    if !fs::is_file(all_hosts) { return Err("the all-hosts profile was not written") }
    if fs::read(all_hosts)? != "# managed by config-weave\nSet-Alias ll Get-ChildItem\n" {
        return Err("the all-hosts profile content is not the one the step declared")
    }

    let text = fs::read(host_profile)?
    // The snippet steps must have touched only their own blocks.
    if !text.contains("# hand written above") { return Err("a hand-written line above the managed block was lost") }
    if !text.contains("# hand written below") { return Err("a hand-written line below the managed block was lost") }
    if text.contains("config-weave: stale") { return Err("the stale block seeded by setup was not removed") }
    if !text.contains("# BEGIN config-weave: greeting") { return Ok(false) }
    if !text.contains("$PSDefaultParameterValues['Export-Csv:NoTypeInformation'] = $true") { return Ok(false) }
    if !text.contains("$ErrorActionPreference = 'Stop'") { return Ok(false) }
    if !text.contains("$ProgressPreference = 'SilentlyContinue'") { return Ok(false) }

    // The preference block setup seeded was removed with no value given.
    if text.contains("WarningPreference") { return Err("the :absent preference block was not removed") }

    // Every block is inserted exactly once, not appended on each run.
    if text.split("# BEGIN config-weave: greeting").len() != 2 { return Err("the greeting block was written more than once") }

    // The profile must still be loadable PowerShell.
    let out = shell::run("pwsh -NoProfile -NonInteractive -Command " + "\"$null = [ScriptBlock]::Create((Get-Content -Raw '" + host_profile + "'))\"", Value::Null)?
    if !out.success { return Err("the generated profile does not parse: " + out.stderr.trim()) }

    // A CRLF profile keeps CRLF on every line after a rewrite.
    let crlf = fs::read("/cwhome/crlf_profile.ps1")?
    if !crlf.contains("# BEGIN config-weave: crlf\r\nSet-Alias gg Get-Location\r\n# END config-weave: crlf\r\n") {
        return Err("the block added to the CRLF profile is missing or lost its CRLF endings: " + crlf)
    }
    if crlf.replace("\r\n", "").contains("\n") { return Err("the CRLF profile now mixes in bare LF line endings") }
    if crlf.contains("config-weave: old") { return Err("the seeded block was not removed from the CRLF profile") }
    if !crlf.contains("# keep\r\n") || !crlf.contains("# keep too\r\n") { return Err("hand-written lines of the CRLF profile were lost") }

    // The unterminated block was refused, and the file left exactly as seeded.
    let broken = fs::read("/cwhome/broken_profile.ps1")?
    if broken != "# BEGIN config-weave: broken\nWrite-Host broken\n# hand written after the unterminated block\n" {
        return Err("the profile with an unterminated block was rewritten: " + broken)
    }

    // The Windows PowerShell 5.1 profile starts with a UTF-8 BOM.
    let bytes = fs::read_bytes("/cwhome/winps_profile.ps1")?
    if bytes.len() < 3 || bytes[0] != 239 || bytes[1] != 187 || bytes[2] != 191 {
        return Err("the Windows PowerShell profile was written without a UTF-8 BOM")
    }
    if !fs::read("/cwhome/winps_profile.ps1")?.contains("Write-Host 'café'") { return Err("the accented content did not survive") }

    // The links planted in the user homes are left alone, and so are their
    // targets: nothing was read, written, deleted or created through them.
    if fs::read_link("/cwlinkhome/.config/powershell/profile.ps1")? != "/root/cw-secret-profile.ps1" { return Err("the planted profile symlink was replaced or removed") }
    if fs::read("/root/cw-secret-profile.ps1")? != "# secret\n" { return Err("the profile symlink's target was changed") }
    if fs::read_link("/cwdirhome/.config")? != "/root/cw-protected" { return Err("the planted .config symlink was replaced or removed") }
    if fs::list_dir("/root/cw-protected/powershell")? != ["profile.ps1"] { return Err("a file was created inside the symlinked directory's target") }
    if fs::read("/root/cw-protected/powershell/profile.ps1")? != "# protected\n" { return Err("a profile was written through the symlinked directory") }
    if fs::read_link("/cwmkhome/.config")? != "/root/cw-empty" { return Err("the planted empty-directory symlink was replaced or removed") }
    if !fs::list_dir("/root/cw-empty")?.is_empty() { return Err("a directory was created inside the symlinked directory's target") }
    Ok(true)
}
