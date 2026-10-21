use value
use log
use common

// UF_DONT_EXPIRE_PASSWD in the SAM userFlags.
fn never_expires_flag() -> string { "0x10000" }

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::account_name("name", name)?
    common::single_line("full_name", common::param_str(params, "full_name", ""))?
    common::single_line("description", common::param_str(params, "description", ""))?
    Ok(name)
}

// account_never_expires = false would mean "the account expires", and that
// needs an expiry date this resource does not take. Only checked when the
// account should be present.
fn account_expiry(params: Value) -> Result[Option[bool], string] {
    let ane = common::param_opt_bool(params, "account_never_expires")
    if ane == Some(false) {
        return Err("account_never_expires = false needs an expiry date, which this resource does not manage; leave it unset or set true")
    }
    Ok(ane)
}

// PowerShell binding $u to the account, or $null when it does not exist. Only
// "not found" reads as absent; access denied or any other failure throws.
fn fetch(name: string) -> string {
    "$u = $null; try {{ $u = Get-LocalUser -Name " + common::ps_q(name) + " }} " +
    "catch [Microsoft.PowerShell.Commands.UserNotFoundException] {{ }}; "
}

// 'ABSENT' or a JSON object { full_name, description, enabled,
// never_expires, account_never_expires, password }. password is
// 'OK'/'BAD'/'LOCKED' when a password was given to test, else ''.
fn probe(name: string, pw: string) -> Result[string, string] {
    let test_pw = if pw != "" {
        common::logon_test_ps() + "$pw = Test-CwPassword " + common::ps_q(name) + " '.' $env:CW_PASSWORD; "
    } else { "$pw = ''; " }
    common::ps_env("reading local user '" + name + "'",
        fetch(name) +
        "if ($null -eq $u) {{ 'ABSENT' }} else {{ " + test_pw +
        "$flags = [int]([ADSI]('WinNT://./' + $u.Name + ',user')).UserFlags.Value; " +
        "[pscustomobject]@{{ full_name = [string]$u.FullName; description = [string]$u.Description; " +
        "enabled = [bool]$u.Enabled; never_expires = [bool]($flags -band " + never_expires_flag() + "); " +
        "account_never_expires = ($null -eq $u.AccountExpires); " +
        "password = [string]$pw }} | ConvertTo-Json -Compress }}",
        secrets(pw))
}

fn secrets(pw: string) -> Map[string, Value] {
    if pw == "" { return #{} }
    #{ "CW_PASSWORD": Value::String(pw) }
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let present = common::want_present(params)?
    let ane = if present { account_expiry(params)? } else { None }
    let pw = if present { common::param_str(params, "password", "") } else { "" }
    let st = probe(name, pw)?
    if !present {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let u = common::parse_json(st)?
    let drift: List[string] = []
    let full = common::param_str(params, "full_name", "")
    if full != "" && common::get_str(u, "full_name") != full { drift.push("full_name") }
    let desc = common::param_str(params, "description", "")
    if desc != "" && common::get_str(u, "description") != desc { drift.push("description") }
    if common::get_bool(u, "enabled") == common::param_bool(params, "disabled", false) { drift.push("disabled") }
    if let Some(ne) = common::param_opt_bool(params, "password_never_expires") {
        if common::get_bool(u, "never_expires") != ne { drift.push("password_never_expires") }
    }
    if ane == Some(true) && !common::get_bool(u, "account_never_expires") { drift.push("account_never_expires") }
    if pw != "" && !common::password_state_err(common::get_str(u, "password"), name)? { drift.push("password") }
    if !drift.is_empty() {
        log::info("local user '" + name + "' differs in: " + drift.join(", "))
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let qn = common::ps_q(name)
    if !common::want_present(params)? {
        common::ps("removing local user '" + name + "'", fetch(name) + "if ($u) {{ Remove-LocalUser -SID $u.SID }}")?
        return Ok(ApplyResult::Success)
    }
    let ane = account_expiry(params)?
    let pw = common::param_str(params, "password", "")
    let full = common::param_str(params, "full_name", "")
    let desc = common::param_str(params, "description", "")
    let attrs = (if full != "" { " -FullName " + common::ps_q(full) } else { "" }) +
        (if desc != "" { " -Description " + common::ps_q(desc) } else { "" })
    let secure = if pw != "" { common::secure_from_env("sp", "CW_PASSWORD") } else { "" }
    let create = if pw == "" {
        "New-LocalUser -Name " + qn + " -NoPassword" + attrs + " | Out-Null; "
    } else {
        "New-LocalUser -Name " + qn + " -Password $sp" + attrs + " | Out-Null; "
    }
    // The password is only re-set when it no longer validates, so a correct
    // one is never rewritten (which would reset its age).
    let reset = if pw != "" {
        common::logon_test_ps() +
        "if ((Test-CwPassword " + qn + " '.' $env:CW_PASSWORD) -ne 'OK') {{ Set-LocalUser -Name " + qn + " -Password $sp }}; "
    } else { "" }
    let updates = (if attrs != "" { "Set-LocalUser -Name " + qn + attrs + "; " } else { "" }) + reset
    let expiry = if let Some(ne) = common::param_opt_bool(params, "password_never_expires") {
        "Set-LocalUser -Name " + qn + " -PasswordNeverExpires " + common::ps_bool(ne) + "; "
    } else { "" }
    let account = if ane == Some(true) { "Set-LocalUser -Name " + qn + " -AccountNeverExpires; " } else { "" }
    let state = if common::param_bool(params, "disabled", false) {
        "Disable-LocalUser -Name " + qn
    } else {
        "Enable-LocalUser -Name " + qn
    }
    common::ps_env("configuring local user '" + name + "'",
        secure + fetch(name) +
        "if ($null -eq $u) {{ " + create + "}} else {{ " + updates + "}}; " + expiry + account + state,
        secrets(pw))?
    Ok(ApplyResult::Success)
}
