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

    // Every block is inserted exactly once, not appended on each run.
    if text.split("# BEGIN config-weave: greeting").len() != 2 { return Err("the greeting block was written more than once") }

    // The profile must still be loadable PowerShell.
    let out = shell::run("pwsh -NoProfile -NonInteractive -Command " + "\"$null = [ScriptBlock]::Create((Get-Content -Raw '" + host_profile + "'))\"", Value::Null)?
    if !out.success { return Err("the generated profile does not parse: " + out.stderr.trim()) }
    Ok(true)
}
