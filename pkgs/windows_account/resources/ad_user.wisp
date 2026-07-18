use value
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
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

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

fn secure(pw: string) -> string {
    "(ConvertTo-SecureString " + ps_q(pw) + " -AsPlainText -Force)"
}

fn ad_guard() -> string {
    "if (-not (Get-Module -ListAvailable ActiveDirectory)) {{ throw 'the ActiveDirectory PowerShell module is required' }}; " +
    "Import-Module ActiveDirectory; "
}

// Fetch into $u, leaving it $null when the identity does not exist; any other
// AD failure (no DC reachable, bad credentials, ...) still throws.
fn fetch(name: string, props: string) -> string {
    "$u = $null; try {{ $u = Get-ADUser -Identity " + ps_q(name) + props + " }} " +
    "catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {{ }}; "
}

// 'ABSENT' or a JSON object { upn, display_name, enabled }.
fn probe(name: string) -> Result[string, string] {
    ps_out(
        ad_guard() + fetch(name, " -Properties DisplayName") +
        "if ($null -eq $u) {{ 'ABSENT' }} else {{ " +
        "[pscustomobject]@{{ upn = \"$($u.UserPrincipalName)\"; display_name = \"$($u.DisplayName)\"; " +
        "enabled = [bool]$u.Enabled }} | ConvertTo-Json -Compress }}"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let st = probe(name)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    // The password is never compared (AD cannot read it back; see
    // force_password) and ou_path is create-only: comparing the DN would
    // leave a moved account permanently unconverged since apply never moves.
    let u = json::parse(st)?
    let upn = param_str(params, "upn", "")
    if upn != "" && get_str(u, "upn") != upn { return Ok(CheckResult::NotConfigured) }
    let display = param_str(params, "display_name", "")
    if display != "" && get_str(u, "display_name") != display { return Ok(CheckResult::NotConfigured) }
    if get_bool(u, "enabled") != param_bool(params, "enabled", true) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = ps_q(name)
    if !want_present(params)? {
        ps_run(ad_guard() + fetch(name, "") + "if ($u) {{ Remove-ADUser -Identity " + qn + " -Confirm:$false }}")?
        return Ok(ApplyResult::Success)
    }
    let pw = param_str(params, "password", "")
    let upn = param_str(params, "upn", "")
    let display = param_str(params, "display_name", "")
    let ou = param_str(params, "ou_path", "")
    let enabled_arg = " -Enabled " + (if param_bool(params, "enabled", true) { "$true" } else { "$false" })
    let shared = (if upn != "" { " -UserPrincipalName " + ps_q(upn) } else { "" }) +
        (if display != "" { " -DisplayName " + ps_q(display) } else { "" })
    // Creating an enabled account without a password fails AD's password
    // policy; the AD error is surfaced as-is.
    let create = "New-ADUser -Name " + qn + " -SamAccountName " + qn + shared +
        (if ou != "" { " -Path " + ps_q(ou) } else { "" }) +
        (if pw != "" { " -AccountPassword " + secure(pw) } else { "" }) +
        enabled_arg
    let updates = "Set-ADUser -Identity " + qn + shared + enabled_arg + "; " +
        (if pw != "" && param_bool(params, "force_password", false) {
            "Set-ADAccountPassword -Identity " + qn + " -Reset -NewPassword " + secure(pw) + "; "
        } else { "" })
    ps_run(
        ad_guard() + fetch(name, "") +
        "if ($null -eq $u) {{ " + create + " }} else {{ " + updates + " }}"
    )?
    Ok(ApplyResult::Success)
}
