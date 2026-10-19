use value
use common
use shell

fn version_of(binary: string) -> Result[string, string] {
    let out = shell::run("\"" + binary + "\" -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if !out.success { return Err(binary + " does not run: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    let want = common::latest_release("stable", "")?
    let msi = version_of("C:\\Program Files\\PowerShell\\7\\pwsh.exe")?
    if msi != want { return Err("the MSI root reports " + msi + ", not the latest release " + want) }
    // winget installed the MSI build: one PowerShell 7 product in the
    // Uninstall key, not an MSIX package beside it.
    let out = shell::run("powershell -NoProfile -NonInteractive -Command \"@(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' -ErrorAction SilentlyContinue | Where-Object {{ [string]$_.DisplayName -like 'PowerShell 7*' -and [string]$_.DisplayName -notlike '*preview*' }}).Count; @(Get-AppxPackage -AllUsers -Name Microsoft.PowerShell -ErrorAction SilentlyContinue).Count\"", Value::Null)?
    let lines = out.stdout.trim().split("\n")
    if lines.len() < 2 || lines[0].trim() != "1" { return Err("expected one PowerShell 7 MSI product, found: " + out.stdout.trim()) }
    if lines[1].trim() != "0" { return Err("winget installed the MSIX package of PowerShell") }
    let zip = version_of("C:\\cw-pwsh-latest\\pwsh.exe")?
    if zip != want { return Err("the zip root reports " + zip + ", not " + want) }
    Ok(true)
}
