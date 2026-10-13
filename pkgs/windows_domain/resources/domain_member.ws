use value
use log
use common

fn validate(params: Value) -> Result[string, string] {
    let domain = common::param_str(params, "domain_name", "")
    common::domain_name("domain_name", domain)?
    let nn = common::param_str(params, "new_name", "")
    if nn != "" {
        if nn.len() > 15 || nn.contains(".") { return Err("'new_name' must be a computer name of at most 15 characters, got '" + nn + "'") }
        common::domain_name("new_name", nn)?
    }
    common::single_line("ou_path", common::param_str(params, "ou_path", ""))?
    common::credential(params)?
    Ok(domain)
}

fn secrets(params: Value) -> Map[string, Value] {
    #{ "CW_CRED_PW": Value::String(common::param_str(params, "credential_password", "")) }
}

// PowerShell binding $comp to this machine's computer object (found through
// the machine's own account, which may always read itself) and $ouOk to
// whether it sits in ou_path. The OU's DN is read back from AD, so spelling
// and case differences do not count.
fn ou_ps(ou: string) -> string {
    "$comp = ([adsisearcher]('(&(objectCategory=computer)(sAMAccountName=' + $env:COMPUTERNAME + '$))')).FindOne(); " +
    "if ($null -eq $comp) {{ throw 'this computer''s account cannot be found in the domain' }}; " +
    "$cdn = [string]$comp.Properties['distinguishedname'][0]; " +
    "$parent = $cdn -replace '^(?:[^,\\\\]|\\\\.)+,', ''; " +
    "$ouDn = [string]([ADSI]('LDAP://' + " + common::ps_q(ou) + ".Replace('/', '\\/'))).distinguishedName; " +
    "if (-not $ouDn) {{ throw ('the OU ' + " + common::ps_q(ou) + " + ' cannot be read') }}; " +
    "$ouOk = ($parent -eq $ouDn); "
}

// 'REBOOT', 'OUT' (not a member of this domain), 'OTHER' (a member of another
// domain), or a JSON object { name_ok, ou_ok } for a member of this domain.
// The domain is matched by DNS or NetBIOS name, case-insensitively.
fn probe(params: Value, domain: string) -> Result[string, string] {
    let nn = common::param_str(params, "new_name", "")
    let ou = common::param_str(params, "ou_path", "")
    common::ps("reading this machine's domain membership",
        common::dsrole_ps() + common::pending_ps("domain_member") +
        "$ds = Get-CwDsRole; " +
        "if ($pending -or $ds.role_reboot) {{ 'REBOOT' }} " +
        "elseif ($ds.role -ne 1 -and $ds.role -lt 3) {{ 'OUT' }} " +
        "elseif ($ds.dns -ine " + common::ps_q(domain) + " -and $ds.netbios -ine " + common::ps_q(domain) + ") {{ 'OTHER' }} " +
        "else {{ " + (if ou != "" { ou_ps(ou) } else { "$ouOk = $true; " }) +
        "[pscustomobject]@{{ name_ok = " + (if nn != "" { "($env:COMPUTERNAME -ieq " + common::ps_q(nn) + ")" } else { "$true" }) +
        "; ou_ok = [bool]$ouOk }} | ConvertTo-Json -Compress }}")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let domain = validate(params)?
    let st = probe(params, domain)?
    if st == "REBOOT" { return Ok(CheckResult::RebootRequired) }
    if !common::want_present(params)? {
        if st == "OUT" || st == "OTHER" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "OUT" || st == "OTHER" { return Ok(CheckResult::NotConfigured) }
    let m = common::parse(st)?
    if !common::get_bool(m, "name_ok") || !common::get_bool(m, "ou_ok") { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn join(params: Value, domain: string, user: string, other: bool) -> Result[ApplyResult, string] {
    let ou = common::param_str(params, "ou_path", "")
    let nn = common::param_str(params, "new_name", "")
    let opts = (if ou != "" { " -OUPath " + common::ps_q(ou) } else { "" }) +
        (if nn != "" { " -NewName " + common::ps_q(nn) } else { "" }) +
        // Moving from another domain needs that domain's unjoin rights too.
        (if other { " -UnjoinDomainCredential $cred" } else { "" })
    log::info("joining " + domain)
    // Add-Computer can join and then fail the rename it was asked for ("the
    // directory service is busy" while the new account settles). The join
    // stands, so the rename is retried on its own; if it still fails, the
    // check after the reboot sees the old name and renames then.
    let rename_retry = if nn != "" {
        "catch {{ if ($_.Exception.Message -notmatch 'successfully joined') {{ throw }}; " +
        "$renamed = $false; for ($i = 0; $i -lt 6 -and -not $renamed; $i++) {{ Start-Sleep -Seconds 10; " +
        "try {{ Rename-Computer -NewName " + common::ps_q(nn) + " -DomainCredential $cred -Force -WarningAction SilentlyContinue; $renamed = $true }} catch {{ }} }} }}; "
    } else { "catch {{ throw }}; " }
    common::ps_env("joining " + domain,
        common::cred_ps(user) +
        "try {{ Add-Computer -DomainName " + common::ps_q(domain) + " -Credential $cred" + opts + " -Force -WarningAction SilentlyContinue | Out-Null }} " +
        rename_retry + common::mark_ps("domain_member"),
        secrets(params))?
    Ok(ApplyResult::RebootRequired)   // joining a domain requires a reboot to finish
}

// A member of the right domain in the wrong OU is moved there with the
// credential, and one under the wrong name is renamed (which needs a reboot).
fn reconcile(params: Value, domain: string, user: string, m: Value) -> Result[ApplyResult, string] {
    let ou = common::param_str(params, "ou_path", "")
    let nn = common::param_str(params, "new_name", "")
    let reboot = !common::get_bool(m, "name_ok")
    let move = if !common::get_bool(m, "ou_ok") {
        log::info("moving this computer's account to " + ou)
        ou_ps(ou) +
        "$guid = (New-Object Guid (,[byte[]]$comp.Properties['objectguid'][0])).ToString(); " +
        "$e = New-Object System.DirectoryServices.DirectoryEntry(('LDAP://<GUID=' + $guid + '>'), " + common::ps_q(user) + ", $env:CW_CRED_PW); " +
        "$t = New-Object System.DirectoryServices.DirectoryEntry(('LDAP://' + $ouDn.Replace('/', '\\/')), " + common::ps_q(user) + ", $env:CW_CRED_PW); " +
        "$e.MoveTo($t); "
    } else { "" }
    let rename = if reboot {
        log::info("renaming this computer to " + nn)
        common::cred_ps(user) +
        "Rename-Computer -NewName " + common::ps_q(nn) + " -DomainCredential $cred -Force -WarningAction SilentlyContinue; " +
        common::mark_ps("domain_member")
    } else { "" }
    common::ps_env("reconciling this computer's account in " + domain, move + rename, secrets(params))?
    if reboot { Ok(ApplyResult::RebootRequired) } else { Ok(ApplyResult::Success) }
}

fn unjoin(params: Value, domain: string) -> Result[ApplyResult, string] {
    let cred = common::credential(params)?
    let creds = if let Some(c) = cred { common::cred_ps(c[0]) + "$o = @{{ UnjoinDomainCredential = $cred }}; " } else { "$o = @{{}}; " }
    log::info("leaving " + domain + " for workgroup WORKGROUP")
    common::ps_env("leaving " + domain,
        creds + "Remove-Computer @o -WorkgroupName WORKGROUP -Force -WarningAction SilentlyContinue; " +
        common::mark_ps("domain_member"),
        secrets(params))?
    Ok(ApplyResult::RebootRequired)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let domain = validate(params)?
    let st = probe(params, domain)?
    if st == "REBOOT" { return Ok(ApplyResult::RebootRequired) }
    if !common::want_present(params)? {
        if st == "OUT" || st == "OTHER" { return Ok(ApplyResult::Success) }
        return unjoin(params, domain)
    }
    let user = if let Some(c) = common::credential(params)? { c[0] } else {
        return Err("joining '" + domain + "' needs 'credential_user' and 'credential_password'")
    }
    if st == "OUT" || st == "OTHER" { return join(params, domain, user, st == "OTHER") }
    reconcile(params, domain, user, common::parse(st)?)
}
