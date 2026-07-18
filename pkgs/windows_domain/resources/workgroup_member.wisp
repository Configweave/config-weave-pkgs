use value
use shell
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// PowerShell that binds $cred to a PSCredential for the given account.
fn ps_cred(user: string, pw: string) -> string {
    "$cp = ConvertTo-SecureString " + ps_q(pw) + " -AsPlainText -Force; " +
    "$cred = New-Object System.Management.Automation.PSCredential(" + ps_q(user) + ", $cp); "
}

// "DOMAIN" when this machine is domain-joined, otherwise "WG:<name>".
fn membership() -> Result[string, string] {
    let script = "$ErrorActionPreference='Stop'; $c = Get-CimInstance Win32_ComputerSystem; " +
        "if ($c.PartOfDomain) {{ 'DOMAIN' }} else {{ 'WG:' + $c.Workgroup }}"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let wg = param_str(params, "workgroup_name", "")
    if wg == "" { return Err("missing 'workgroup_name' parameter") }
    if membership()? == "WG:" + wg { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let wg = param_str(params, "workgroup_name", "")
    if wg == "" { return Err("missing 'workgroup_name' parameter") }

    let user = param_str(params, "credential_user", "")
    let cpw = param_str(params, "credential_password", "")
    let in_domain = membership()? == "DOMAIN"

    // Leaving a domain needs an account allowed to unjoin; a plain
    // workgroup-to-workgroup move does not.
    let creds = if user != "" && cpw != "" { ps_cred(user, cpw) } else { "" }
    let o_unjoin = if in_domain && creds != "" { " -UnjoinDomainCredential $cred" } else { "" }
    if in_domain && creds == "" {
        log::info("leaving the domain without explicit credentials — the current account must have unjoin rights")
    }

    if in_domain {
        log::info("leaving the domain and joining workgroup " + wg)
    } else {
        log::info("moving to workgroup " + wg)
    }
    let script = "$ErrorActionPreference='Stop'; " + creds +
        "Add-Computer -WorkgroupName " + ps_q(wg) + o_unjoin + " -Force | Out-Null"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err("workgroup join failed: " + out.stderr.trim()) }
    Ok(ApplyResult::RebootRequired)   // membership changes require a reboot to finish
}
