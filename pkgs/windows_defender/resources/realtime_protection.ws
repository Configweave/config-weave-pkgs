use value
use common

// PowerShell binding $st to the effective real-time protection state, read
// from Get-MpComputerStatus rather than the preference: the preference says
// what was asked for, the status says whether the engine is scanning.
// Passive mode (another AV is primary) and a Group Policy value both
// override the preference, so they are named instead of read as drift.
fn status_ps() -> string {
    "$s = Get-MpComputerStatus; " +
    "if ([string]$s.AMRunningMode -ne 'Normal') {{ throw ('Defender is running in ' + $s.AMRunningMode + ' mode, where real-time protection is not under its own control') }}; " +
    "$pol = Get-ItemProperty -Path 'HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows Defender\\Real-Time Protection' -Name DisableRealtimeMonitoring -ErrorAction SilentlyContinue; " +
    "$gpo = if ($pol) {{ [int]$pol.DisableRealtimeMonitoring }} else {{ -1 }}; "
}

fn policy_err(want_enabled: bool) -> string {
    let conflict = if want_enabled { "1" } else { "0" }
    "if ($gpo -eq " + conflict + ") {{ throw 'Group Policy (DisableRealtimeMonitoring under HKLM\\SOFTWARE\\Policies\\Microsoft\\Windows Defender\\Real-Time Protection) sets the opposite state' }}; "
}

fn check(params: Value) -> Result[CheckResult, string] {
    let want = common::param_bool(params, "enabled", true)
    let cur = common::ps("reading the real-time protection state",
        status_ps() + policy_err(want) + "[string][bool]$s.RealTimeProtectionEnabled")?
    let want_s = if want { "True" } else { "False" }
    if cur == want_s { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let want = common::param_bool(params, "enabled", true)
    let want_ps = if want { "$true" } else { "$false" }
    let arg = if want { "$false" } else { "$true" }
    // The engine takes a moment to switch, so the status is polled. With
    // Tamper Protection on, Set-MpPreference succeeds but nothing changes;
    // that is reported as such rather than left to the re-check.
    common::ps("setting real-time protection",
        status_ps() + policy_err(want) +
        "Set-MpPreference -DisableRealtimeMonitoring " + arg + "; " +
        "for ($i = 0; $i -lt 20; $i++) {{ if ([bool](Get-MpComputerStatus).RealTimeProtectionEnabled -eq " + want_ps + ") {{ break }}; Start-Sleep -Milliseconds 500 }}; " +
        "$s = Get-MpComputerStatus; " +
        "if ([bool]$s.RealTimeProtectionEnabled -ne " + want_ps + ") {{ " +
        "if ($s.IsTamperProtected) {{ throw 'Tamper Protection is on and kept real-time protection from changing' }}; " +
        "throw 'real-time protection did not change state after Set-MpPreference' }}")?
    Ok(ApplyResult::Success)
}
