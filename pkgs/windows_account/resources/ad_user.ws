use value
use common

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::account_name("name", name)?
    for key in ["upn", "display_name", "ou_path"] {
        common::single_line(key, common::param_str(params, key, ""))?
    }
    Ok(name)
}

fn secrets(pw: string) -> Map[string, Value] {
    if pw == "" { return #{} }
    #{ "CW_PASSWORD": Value::String(pw) }
}

// Fetch into $u, leaving it $null when the identity does not exist; any other
// AD failure (no DC reachable, bad credentials, ...) still throws.
fn fetch(name: string, props: string) -> string {
    "$u = $null; try {{ $u = Get-ADUser @srv -Identity " + common::ps_q(name) + props + " }} " +
    "catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {{ }}; "
}

// PowerShell binding $pwState to the password probe for the account in $u.
// The logon goes through this machine's own domain logon path, so the
// password is checked against the PDC emulator when a DC has an older copy.
fn password_probe() -> string {
    common::logon_test_ps() +
    "$pwState = Test-CwPassword $u.SamAccountName (Get-ADDomain @srv).NetBIOSName $env:CW_PASSWORD; "
}

// 'ABSENT' or a JSON object { upn, display_name, enabled, ou_ok, password }.
fn probe(params: Value, name: string, pw: string) -> Result[string, string] {
    let ou = common::param_str(params, "ou_path", "")
    let test_pw = if pw != "" { password_probe() } else { "$pwState = ''; " }
    common::ps_env("reading AD user '" + name + "'",
        common::ad_prelude(params)? + fetch(name, " -Properties DisplayName") +
        "if ($null -eq $u) {{ 'ABSENT' }} else {{ $dn = $u.DistinguishedName; " + common::ou_match_ps(ou) + test_pw +
        "[pscustomobject]@{{ upn = [string]$u.UserPrincipalName; display_name = [string]$u.DisplayName; " +
        "enabled = [bool]$u.Enabled; ou_ok = [bool]$ouOk; password = [string]$pwState }} | ConvertTo-Json -Compress }}",
        secrets(pw))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let pw = if present { common::param_str(params, "password", "") } else { "" }
    let st = probe(params, name, pw)?
    if !present {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let u = common::parse_json(st)?
    let upn = common::param_str(params, "upn", "")
    if upn != "" && common::get_str(u, "upn").to_lower() != upn.to_lower() { return Ok(CheckResult::NotConfigured) }
    let display = common::param_str(params, "display_name", "")
    if display != "" && common::get_str(u, "display_name") != display { return Ok(CheckResult::NotConfigured) }
    if common::get_bool(u, "enabled") != common::param_bool(params, "enabled", true) { return Ok(CheckResult::NotConfigured) }
    if !common::get_bool(u, "ou_ok") { return Ok(CheckResult::NotConfigured) }
    if pw != "" && !common::password_state_err(common::get_str(u, "password"), name)? {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let qn = common::ps_q(name)
    let prelude = common::ad_prelude(params)?
    if !common::want_present(params)? {
        common::ps("removing AD user '" + name + "'",
            prelude + fetch(name, "") + "if ($u) {{ Remove-ADUser @srv -Identity $u.ObjectGUID -Confirm:$false }}")?
        return Ok(ApplyResult::Success)
    }
    let pw = common::param_str(params, "password", "")
    let upn = common::param_str(params, "upn", "")
    let display = common::param_str(params, "display_name", "")
    let ou = common::param_str(params, "ou_path", "")
    let enabled_arg = " -Enabled " + common::ps_bool(common::param_bool(params, "enabled", true))
    let shared = (if upn != "" { " -UserPrincipalName " + common::ps_q(upn) } else { "" }) +
        (if display != "" { " -DisplayName " + common::ps_q(display) } else { "" })
    let secure = if pw != "" { common::secure_from_env("sp", "CW_PASSWORD") } else { "" }
    // Creating an enabled account without a password fails AD's password
    // policy; the AD error is surfaced as-is.
    let create = "New-ADUser @srv -Name " + qn + " -SamAccountName " + qn + shared +
        (if ou != "" { " -Path " + common::ps_q(ou) } else { "" }) +
        (if pw != "" { " -AccountPassword $sp" } else { "" }) +
        enabled_arg + "; "
    // The password is reset only when it no longer validates, and before the
    // account is enabled, which AD refuses for an account without one.
    let reset = if pw != "" {
        password_probe() +
        "if ($pwState -ne 'OK') {{ Set-ADAccountPassword @srv -Identity $u.ObjectGUID -Reset -NewPassword $sp }}; "
    } else { "" }
    let move = if ou != "" {
        "$dn = $u.DistinguishedName; " + common::ou_match_ps(ou) +
        "if (-not $ouOk) {{ Move-ADObject @srv -Identity $u.ObjectGUID -TargetPath $ouObj.DistinguishedName }}; "
    } else { "" }
    let updates = reset + "Set-ADUser @srv -Identity $u.ObjectGUID" + shared + enabled_arg + "; " + move
    common::ps_env("configuring AD user '" + name + "'",
        prelude + secure + fetch(name, "") +
        "if ($null -eq $u) {{ " + create + "}} else {{ " + updates + "}}",
        secrets(pw))?
    Ok(ApplyResult::Success)
}
