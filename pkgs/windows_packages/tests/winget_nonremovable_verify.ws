use value
use json
use common

fn verify(facts: Value) -> Result[bool, string] {
    let script = "$pk = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller)\n" +
        common::winget_ps() +
        "ConvertTo-Json -Compress @{{ installed = $pk.Count; shim = (Test-Path (Join-Path $env:SystemRoot 'System32\\winget.cmd')); winget = [string]$winget }}\n"
    let out = common::query(script, #{})?
    if out.code == common::missing_code() { return Err("winget no longer starts: the refused :absent changed something") }
    if !out.success { return Err(common::failure("reading App Installer state", out)) }
    let s = json::parse(out.stdout.trim())?
    if common::get_bool(s, "shim") { return Err("system_shim = false left the shim in place") }
    if common::get_int(s, "installed") < 1 { return Err("App Installer was removed although :absent was refused") }
    if !common::get_str(s, "winget").contains("WindowsApps") { return Err("winget is not run from WindowsApps: " + common::get_str(s, "winget")) }
    Ok(true)
}
