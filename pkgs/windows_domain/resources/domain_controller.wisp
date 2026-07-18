use value
use shell
use log

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
    Err("invalid 'ensure' value '" + e + "' (expected \"present\" or \"absent\")")
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// PowerShell that binds $cred to a PSCredential for the given account.
fn ps_cred(user: string, pw: string) -> string {
    "$cp = ConvertTo-SecureString " + ps_q(pw) + " -AsPlainText -Force; " +
    "$cred = New-Object System.Management.Automation.PSCredential(" + ps_q(user) + ", $cp); "
}

// True when this machine is a DC whose domain matches `domain`.
// Win32_ComputerSystem.DomainRole: 4 = backup DC, 5 = primary DC.
fn is_dc_for(domain: string) -> Result[bool, string] {
    let script = "$ErrorActionPreference='Stop'; $c = Get-CimInstance Win32_ComputerSystem; " +
        "if ($c.DomainRole -ge 4 -and $c.Domain -eq " + ps_q(domain) + ") {{ 'YES' }} else {{ 'NO' }}"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "YES")
}

// True when this machine is a DC for ANY domain (the demotion check).
fn is_dc() -> Result[bool, string] {
    let script = "$ErrorActionPreference='Stop'; " +
        "if ((Get-CimInstance Win32_ComputerSystem).DomainRole -ge 4) {{ 'YES' }} else {{ 'NO' }}"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "YES")
}

// True when a DC for `domain` is discoverable from this machine (nltest is
// built in, needs no credentials, and asks the locator the same way a join
// would). Undiscoverable means we are the first DC and create the forest —
// so DNS must already point at an existing DC when one exists, or a
// same-named second forest results.
fn domain_exists(domain: string) -> Result[bool, string] {
    let script = "nltest /dsgetdc:" + ps_q(domain) + " *> $null; " +
        "if ($LASTEXITCODE -eq 0) {{ 'YES' }} else {{ 'NO' }}"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "YES")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let domain = param_str(params, "domain_name", "")
    if domain == "" { return Err("missing 'domain_name' parameter") }
    if want_present(params)? {
        if is_dc_for(domain)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
    } else {
        if is_dc()? { Ok(CheckResult::NotConfigured) } else { Ok(CheckResult::AlreadyConfigured) }
    }
}

// Promote into an existing domain (additional DC) — requires credentials.
fn promote_additional(params: Value, domain: string, pw: string) -> Result[ApplyResult, string] {
    let user = param_str(params, "credential_user", "")
    let cpw = param_str(params, "credential_password", "")
    if user == "" || cpw == "" {
        return Err("domain '" + domain + "' already exists — joining it as an additional DC needs 'credential_user' and 'credential_password'")
    }

    let site = param_str(params, "site_name", "")
    let o_site = if site != "" { " -SiteName " + ps_q(site) } else { "" }
    let dbp = param_str(params, "database_path", "")
    let o_dbp = if dbp != "" { " -DatabasePath " + ps_q(dbp) } else { "" }
    let lp = param_str(params, "log_path", "")
    let o_lp = if lp != "" { " -LogPath " + ps_q(lp) } else { "" }
    let sv = param_str(params, "sysvol_path", "")
    let o_sv = if sv != "" { " -SysvolPath " + ps_q(sv) } else { "" }
    let opts = o_site + o_dbp + o_lp + o_sv
    let dns = if param_bool(params, "install_dns", true) { "$true" } else { "$false" }

    log::info("domain " + domain + " is reachable — promoting as an additional DC")
    let script = "$ErrorActionPreference='Stop'; Import-Module ADDSDeployment; " +
        ps_cred(user, cpw) +
        "$smp = ConvertTo-SecureString " + ps_q(pw) + " -AsPlainText -Force; " +
        "Install-ADDSDomainController -DomainName " + ps_q(domain) +
        " -Credential $cred -SafeModeAdministratorPassword $smp -InstallDns:" + dns +
        opts + " -Force -NoRebootOnCompletion | Out-Null"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err("domain controller promotion failed: " + out.stderr.trim()) }
    Ok(ApplyResult::RebootRequired)   // DC promotion always needs a reboot to finish
}

// No DC answers for the domain: create it (new forest, first DC).
fn promote_first(params: Value, domain: string, pw: string) -> Result[ApplyResult, string] {
    let nb = param_str(params, "netbios_name", "")
    let o_nb = if nb != "" { " -DomainNetbiosName " + ps_q(nb) } else { "" }
    let fm = param_str(params, "forest_mode", "")
    let o_fm = if fm != "" { " -ForestMode " + ps_q(fm) } else { "" }
    let dm = param_str(params, "domain_mode", "")
    let o_dm = if dm != "" { " -DomainMode " + ps_q(dm) } else { "" }
    let dbp = param_str(params, "database_path", "")
    let o_dbp = if dbp != "" { " -DatabasePath " + ps_q(dbp) } else { "" }
    let lp = param_str(params, "log_path", "")
    let o_lp = if lp != "" { " -LogPath " + ps_q(lp) } else { "" }
    let sv = param_str(params, "sysvol_path", "")
    let o_sv = if sv != "" { " -SysvolPath " + ps_q(sv) } else { "" }
    let opts = o_nb + o_fm + o_dm + o_dbp + o_lp + o_sv
    let dns = if param_bool(params, "install_dns", true) { "$true" } else { "$false" }

    log::info("no DC answers for " + domain + " — creating the forest (first DC)")
    let script = "$ErrorActionPreference='Stop'; Import-Module ADDSDeployment; " +
        "$smp = ConvertTo-SecureString " + ps_q(pw) + " -AsPlainText -Force; " +
        "Install-ADDSForest -DomainName " + ps_q(domain) +
        " -SafeModeAdministratorPassword $smp -InstallDns:" + dns +
        opts + " -Force -NoRebootOnCompletion | Out-Null"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err("forest promotion failed: " + out.stderr.trim()) }
    Ok(ApplyResult::RebootRequired)   // DC promotion always needs a reboot to finish
}

// Demote this DC (ensure = "absent").
fn demote(params: Value) -> Result[ApplyResult, string] {
    let lap = param_str(params, "local_admin_password", "")
    if lap == "" { return Err("demoting a DC needs 'local_admin_password' (the machine's local Administrator password after demotion)") }

    let user = param_str(params, "credential_user", "")
    let cpw = param_str(params, "credential_password", "")
    let creds = if user != "" && cpw != "" { ps_cred(user, cpw) } else { "" }
    let o_cred = if creds != "" { " -Credential $cred" } else { "" }
    // The last DC takes the domain (and its partitions / DNS zone) with it.
    let o_last = if param_bool(params, "last_dc_in_domain", false) {
        " -LastDomainControllerInDomain -RemoveApplicationPartitions -IgnoreLastDnsServerForZone"
    } else { "" }
    let o_force = if param_bool(params, "force_removal", false) { " -ForceRemoval" } else { "" }

    log::info("demoting this domain controller")
    let script = "$ErrorActionPreference='Stop'; Import-Module ADDSDeployment; " +
        creds +
        "$lap = ConvertTo-SecureString " + ps_q(lap) + " -AsPlainText -Force; " +
        "Uninstall-ADDSDomainController -LocalAdministratorPassword $lap" +
        o_cred + o_last + o_force + " -Force -NoRebootOnCompletion | Out-Null"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err("domain controller demotion failed: " + out.stderr.trim()) }
    Ok(ApplyResult::RebootRequired)   // demotion always needs a reboot to finish
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let domain = param_str(params, "domain_name", "")
    if domain == "" { return Err("missing 'domain_name' parameter") }

    if !want_present(params)? {
        if !is_dc()? { return Ok(ApplyResult::Success) }
        return demote(params)
    }

    let pw = param_str(params, "safe_mode_password", "")
    if pw == "" { return Err("missing 'safe_mode_password' parameter") }
    if domain_exists(domain)? {
        promote_additional(params, domain, pw)
    } else {
        promote_first(params, domain, pw)
    }
}
