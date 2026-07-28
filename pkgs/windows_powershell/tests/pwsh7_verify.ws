use value
use fs
use shell
use json

fn verify(facts: Value) -> Result[bool, string] {
    let binary = "C:\\Program Files\\PowerShell\\7\\pwsh.exe"
    if !fs::is_file(binary) { return Err("the MSI did not install PowerShell 7 at " + binary) }

    let out = shell::run("\"" + binary + "\" -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if !out.success { return Err("the installed pwsh does not run: " + out.stderr.trim()) }
    if out.stdout.trim() != "7.5.4" { return Err("the installed pwsh reports " + out.stdout.trim() + ", not the pinned 7.5.4") }

    // The remoting endpoints, the AllUsers module and the machine-wide
    // profile the later steps produced.
    let probe = "$e = @(Get-PSSessionConfiguration -Name 'PowerShell.7*' -ErrorAction SilentlyContinue).Count\n$m = @(Get-Module -ListAvailable -Name PSWriteColor | ForEach-Object {{ [string]$_.Version }}) -join ','\nWrite-Output $e\nWrite-Output $m"
    let script = "C:\\weave-ps7-verify.ps1"
    fs::write(script, "$ErrorActionPreference = 'Stop'\n" + probe)?
    let checked = shell::run("\"" + binary + "\" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File \"" + script + "\"", Value::Null)?
    fs::delete(script)?
    if !checked.success { return Err("the post-install probe failed: " + checked.stderr.trim()) }
    let lines = checked.stdout.split("\n")
    if lines.len() < 2 { return Err("unexpected probe output: " + checked.stdout) }
    if lines[0].trim().parse_int().unwrap_or(0) < 1 { return Err("no PowerShell.7 remoting endpoint was registered") }
    if !lines[1].contains("1.0.1") { return Err("the AllUsers module install is not visible, found: " + lines[1].trim()) }

    let profile = "C:\\Program Files\\PowerShell\\7\\profile.ps1"
    if !fs::is_file(profile) { return Err("the machine-wide profile was not written") }

    let config = "C:\\Program Files\\PowerShell\\7\\powershell.config.json"
    if !fs::is_file(config) { return Err("the real $PSHOME configuration file was not written") }
    let doc = json::parse(fs::read(config)?)?
    let features: List[string] = []
    if let Some(items) = doc.get("ExperimentalFeatures") {
        if let Some(list) = items.as_list() {
            for item in list { features.push(item.as_string().unwrap_or("")) }
        }
    }
    if !features.contains("PSCommandNotFoundSuggestion") {
        return Err("the experimental feature was not written to the real $PSHOME configuration file")
    }
    Ok(true)
}
