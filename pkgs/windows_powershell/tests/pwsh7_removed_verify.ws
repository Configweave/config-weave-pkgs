use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    if fs::exists("C:\\Program Files\\PowerShell\\7\\pwsh.exe") { return Err("the MSI install of PowerShell 7 is still there") }
    if fs::exists("C:\\Program Files\\PowerShell\\7.4.6") { return Err("the zip root was not removed") }
    let out = shell::run("powershell -NoProfile -NonInteractive -Command \"@(Get-ItemProperty 'HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\*' -ErrorAction SilentlyContinue | Where-Object {{ [string]$_.DisplayName -like 'PowerShell 7*' }}).Count\"", Value::Null)?
    if !out.success { return Err("reading the Uninstall key failed: " + out.stderr.trim()) }
    if out.stdout.trim() != "0" { return Err("an Uninstall entry for PowerShell 7 remains (" + out.stdout.trim() + ")") }
    Ok(true)
}
