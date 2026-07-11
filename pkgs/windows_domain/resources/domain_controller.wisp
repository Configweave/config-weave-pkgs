use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// PowerShell that binds $cred to a PSCredential for the given account.
fn ps_cred(user: string, pw: string) -> string {
    "$cp = ConvertTo-SecureString " + ps_q(pw) + " -AsPlainText -Force; " +
    "$cred = New-Object System.Management.Automation.PSCredential(" + ps_q(user) + ", $cp); "
}

// True when this machine is already a DC whose domain matches `domain`.
// Win32_ComputerSystem.DomainRole: 4 = backup DC, 5 = primary DC.
fn is_dc_for(domain: string) -> Result[bool, string] {
    let script = "$ErrorActionPreference='Stop'; $c = Get-CimInstance Win32_ComputerSystem; " +
        "if ($c.DomainRole -ge 4 -and $c.Domain -eq " + ps_q(domain) + ") {{ 'YES' }} else {{ 'NO' }}"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "YES")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let domain = param_str(params, "domain_name", "")
    if domain == "" { return Err("missing 'domain_name' parameter") }
    if is_dc_for(domain)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let domain = param_str(params, "domain_name", "")
    let pw = param_str(params, "safe_mode_password", "")
    let user = param_str(params, "credential_user", "")
    let cpw = param_str(params, "credential_password", "")
    if domain == "" { return Err("missing 'domain_name' parameter") }
    if pw == "" { return Err("missing 'safe_mode_password' parameter") }
    if user == "" { return Err("missing 'credential_user' parameter") }
    if cpw == "" { return Err("missing 'credential_password' parameter") }

    // optional flags, appended only when set
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
