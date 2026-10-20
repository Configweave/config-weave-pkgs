use value
use shell
use common

fn version_of(binary: string) -> Result[string, string] {
    let out = shell::run("\"" + binary + "\" -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if !out.success { return Err(binary + " does not run: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    let stable = common::latest_release("stable", "")?
    let preview = common::latest_release("preview", "")?
    let msi = version_of("C:\\Program Files\\PowerShell\\7\\pwsh.exe")?
    if msi != stable { return Err("the MSI root reports " + msi + ", not the latest release " + stable) }
    // winget upgraded the MSI rather than adding the MSIX: one stable MSI
    // product, and no MSIX package.
    let out = shell::run("powershell -NoProfile -NonInteractive -Command \"@(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' -ErrorAction SilentlyContinue | Where-Object {{ [string]$_.DisplayName -like 'PowerShell 7*' -and [string]$_.DisplayName -notlike '*preview*' }}).Count; @(Get-AppxPackage -AllUsers -Name Microsoft.PowerShell* -ErrorAction SilentlyContinue).Count\"", Value::Null)?
    let lines = out.stdout.trim().split("\n")
    if lines.len() < 2 || lines[0].trim() != "1" { return Err("expected one PowerShell 7 MSI product, found: " + out.stdout.trim()) }
    if lines[1].trim() != "0" { return Err("winget installed an MSIX package of PowerShell") }
    let zip = version_of("C:\\cw-pwsh-preview\\pwsh.exe")?
    if zip != preview { return Err("the preview zip root reports " + zip + ", not the latest preview " + preview) }
    Ok(true)
}
