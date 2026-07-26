use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn ad_guard() -> string {
    "if (-not (Get-Module -ListAvailable ActiveDirectory)) {{ throw 'the ActiveDirectory PowerShell module is required' }}; " +
    "Import-Module ActiveDirectory; "
}

// 'PRESENT', 'ABSENT' or 'NOGROUP' (the group itself does not exist).
fn probe(group: string, member: string) -> Result[string, string] {
    let qm = ps_q(member)
    ps_out(
        ad_guard() +
        "$st = 'NOGROUP'; try {{ " +
        "$hits = @(Get-ADGroupMember -Identity " + ps_q(group) + " | " +
        "Where-Object {{ $_.SamAccountName -eq " + qm + " -or $_.Name -eq " + qm + " }}); " +
        "$st = $(if ($hits.Count -gt 0) {{ 'PRESENT' }} else {{ 'ABSENT' }}) " +
        "}} catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {{ }}; $st"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let group = param_str(params, "group", "")
    if group == "" { return Err("missing 'group' parameter") }
    let member = param_str(params, "member", "")
    if member == "" { return Err("missing 'member' parameter") }
    let st = probe(group, member)?
    if want_present(params)? {
        if st == "PRESENT" { return Ok(CheckResult::AlreadyConfigured) }
        // NOGROUP is NotConfigured too: apply then surfaces the real AD error.
        return Ok(CheckResult::NotConfigured)
    }
    if st == "PRESENT" { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let group = param_str(params, "group", "")
    if group == "" { return Err("missing 'group' parameter") }
    let member = param_str(params, "member", "")
    if member == "" { return Err("missing 'member' parameter") }
    let qg = ps_q(group)
    let qm = ps_q(member)
    if want_present(params)? {
        ps_run(ad_guard() + "Add-ADGroupMember -Identity " + qg + " -Members " + qm)?
        return Ok(ApplyResult::Success)
    }
    // A vanished group means the membership is gone as well.
    ps_run(
        ad_guard() +
        "try {{ Remove-ADGroupMember -Identity " + qg + " -Members " + qm + " -Confirm:$false }} " +
        "catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {{ }}"
    )?
    Ok(ApplyResult::Success)
}
