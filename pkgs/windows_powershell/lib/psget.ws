// Choosing between the two generations of the repository and module
// cmdlets: PowerShellGet v2 and PSResourceGet v3.
use value
use common

// Probing the cmdlet rather than listing the module: PSResourceGet ships
// inside PowerShell 7 and stays usable even when PSModulePath has been
// overridden so that Get-Module -ListAvailable no longer finds it. Getting
// this wrong falls back to the v2 cmdlets, which under pwsh on Windows go
// through the Windows PowerShell compatibility layer and can block.
fn provider(params: Value) -> Result[string, string] {
    let requested = common::param_str(params, "provider", "auto")
    if requested == "psresourceget" { return Ok("psresourceget") }
    if requested == "powershellget" { return Ok("powershellget") }
    if requested != "auto" { return Err("invalid 'provider' value '" + requested + "'") }
    let edition = common::param_str(params, "edition", "auto")
    let probe = "if (Get-Command Get-PSResourceRepository -ErrorAction SilentlyContinue) {{ Write-Output 'psresourceget' }} else {{ Write-Output 'powershellget' }}"
    // The edition not being installed yet (run 1 checks every step before
    // the install step has applied) falls back to its usual generation.
    if let Some(detected) = common::query(edition, probe)? {
        if detected != "" { return Ok(detected) }
    }
    if common::resolved_edition(edition) == "windows_powershell" { return Ok("powershellget") }
    Ok("psresourceget")
}

fn import_line(kind: string) -> string {
    if kind == "psresourceget" { return "Import-Module Microsoft.PowerShell.PSResourceGet\n" }
    ""
}

// A PSResourceGet range such as "[1.0.0, 3.0.0)" cannot be evaluated here.
fn is_range(version: string) -> bool {
    version.starts_with("[") || version.starts_with("(")
}
