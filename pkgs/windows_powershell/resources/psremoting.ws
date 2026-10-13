use value
use sys
use service
use common

// Enable-PSRemoting registers endpoints for whichever PowerShell runs it, so
// the edition is what picks between microsoft.powershell (5.1) and the
// PowerShell.7 endpoints — there is no switch that does it.
fn endpoint_filter(params: Value) -> string {
    let explicit = common::param_str(params, "configuration_name", "")
    if explicit != "" { return explicit }
    if common::resolved_edition(common::param_str(params, "edition", "auto")) == "windows_powershell" { return "microsoft.powershell" }
    "PowerShell.7*"
}

// True when at least one matching endpoint exists and is enabled. With the
// WinRM service stopped nothing is reachable, which is "not enabled"; with
// the edition not installed there is nothing to ask. Any other failure is an
// error, never "disabled".
fn endpoint_enabled(params: Value) -> Result[bool, string] {
    let winrm = service::status("WinRM")?
    if winrm != "running" { return Ok(false) }
    let script = "$filter = " + common::ps_q(endpoint_filter(params)) + "\n$c = @(Get-PSSessionConfiguration -ErrorAction Stop | Where-Object {{ $_.Name -like $filter -and ([string]$_.Enabled).ToLower() -eq 'true' }})\nif ($c.Count -gt 0) {{ Write-Output 'yes' }} else {{ Write-Output 'no' }}"
    if let Some(answer) = common::query(common::param_str(params, "edition", "auto"), script)? { return Ok(answer == "yes") }
    Ok(false)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if sys::family() != "windows" {
        return Err("WS-Management PowerShell remoting is only supported on Windows")
    }
    let enabled = endpoint_enabled(params)?
    if common::want_present(params)? {
        if enabled { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if enabled { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if sys::family() != "windows" {
        return Err("WS-Management PowerShell remoting is only supported on Windows")
    }
    let edition = common::param_str(params, "edition", "auto")
    if !common::ps_installed(edition) { return Err(common::not_installed(edition)) }
    let script = ""
    if common::want_present(params)? {
        let args = " -Force"
        if common::param_bool(params, "skip_network_profile_check", false) { args = args + " -SkipNetworkProfileCheck" }
        script = "Enable-PSRemoting" + args
    } else {
        script = "$filter = " + common::ps_q(endpoint_filter(params)) + "\nGet-PSSessionConfiguration -ErrorAction Stop | Where-Object {{ $_.Name -like $filter }} | ForEach-Object {{ Disable-PSSessionConfiguration -Name $_.Name -Force -NoServiceRestart }}"
    }
    let out = common::run_ps_streaming(edition, script, 600)?
    if !out.success { return Err(common::failure("configuring PowerShell remoting", out)) }
    Ok(ApplyResult::Success)
}
