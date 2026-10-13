use value
use log
use common

fn validate(params: Value) -> Result[string, string] {
    let wg = common::param_str(params, "workgroup_name", "")
    common::domain_name("workgroup_name", wg)?
    if wg.len() > 15 || wg.contains(".") { return Err("'workgroup_name' must be a NetBIOS name of at most 15 characters, got '" + wg + "'") }
    common::credential(params)?
    Ok(wg)
}

// 'REBOOT', 'DOMAIN' when domain-joined, otherwise 'WG:<name>'.
fn membership() -> Result[string, string] {
    common::ps("reading this machine's membership",
        common::pending_ps("workgroup_member") +
        "$c = Get-CimInstance Win32_ComputerSystem; " +
        "if ($pending) {{ 'REBOOT' }} elseif ($c.PartOfDomain) {{ 'DOMAIN' }} else {{ 'WG:' + $c.Workgroup }}")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let wg = validate(params)?
    let st = membership()?
    if st == "REBOOT" { return Ok(CheckResult::RebootRequired) }
    // NetBIOS names, workgroups included, are case-insensitive.
    if st.to_upper() == ("WG:" + wg).to_upper() { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let wg = validate(params)?
    let st = membership()?
    if st == "REBOOT" { return Ok(ApplyResult::RebootRequired) }
    let in_domain = st == "DOMAIN"

    // Leaving a domain needs an account allowed to unjoin; a plain
    // workgroup-to-workgroup move does not.
    let cred = common::credential(params)?
    let creds = if let Some(c) = cred { if in_domain { common::cred_ps(c[0]) + "$o = @{{ UnjoinDomainCredential = $cred }}; " } else { "$o = @{{}}; " } } else { "$o = @{{}}; " }
    if in_domain && cred.is_none() {
        log::info("leaving the domain without explicit credentials — the current account must have unjoin rights")
    }
    if in_domain {
        log::info("leaving the domain and joining workgroup " + wg)
    } else {
        log::info("moving to workgroup " + wg)
    }
    common::ps_env("joining workgroup " + wg,
        creds + "Add-Computer -WorkgroupName " + common::ps_q(wg) + " @o -Force -WarningAction SilentlyContinue | Out-Null; " +
        common::mark_ps("workgroup_member"),
        #{ "CW_CRED_PW": Value::String(common::param_str(params, "credential_password", "")) })?
    Ok(ApplyResult::RebootRequired)   // membership changes require a reboot to finish
}
