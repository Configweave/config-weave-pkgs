// The Group Policy registry keys PowerShell reads.
use value
use registry

// Windows PowerShell 5.1 reads ...\Policies\Microsoft\Windows\PowerShell;
// PowerShell 7 reads ...\Policies\Microsoft\PowerShellCore.
fn policy_root(edition: string, hive: string) -> Result[string, string] {
    if edition == "windows_powershell" { return Ok(hive + "\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell") }
    if edition == "pwsh" { return Ok(hive + "\\SOFTWARE\\Policies\\Microsoft\\PowerShellCore") }
    Err("invalid 'edition' value '" + edition + "' (expected :windows_powershell or :pwsh)")
}

// A missing value reads as -1 so it can never look like a deliberate 0.
fn current_dword(key: string, name: string) -> Result[int, string] {
    if let Some(v) = registry::read(key, name)? {
        if let Some(n) = v.as_int() { return Ok(n) }
    }
    Ok(-1)
}

fn current_sz(key: string, name: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, name)? {
        if let Some(s) = v.as_string() { return Ok(s) }
    }
    Ok("")
}

// :enabled / :disabled / :unmanaged toggles, as the DWORD they stand for.
fn toggle(want: string, key: string) -> Result[Option[int], string] {
    if want == "unmanaged" { return Ok(None) }
    if want == "enabled" { return Ok(Some(1)) }
    if want == "disabled" { return Ok(Some(0)) }
    Err("invalid '" + key + "' value '" + want + "' (expected :enabled, :disabled or :unmanaged)")
}

// The value an ensure-driven policy switch must hold. A policy that was never
// written (-1) already satisfies :absent: unset and 0 both mean "off".
fn switch_converged(current: int, present: bool) -> bool {
    if present { return current == 1 }
    current == 0 || current == -1
}
