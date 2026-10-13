use value
use registry
use common
use policy

// Only PowerShell 7 has this policy; Windows PowerShell 5.1 has no
// equivalent setting, so the PowerShellCore key is the only one.
fn key(params: Value) -> Result[string, string] {
    let edition = common::param_str(params, "edition", "pwsh")
    if edition != "pwsh" { return Err("the console session configuration policy exists only for PowerShell 7 (edition :pwsh)") }
    Ok(policy::policy_root(edition, registry::HKLM)? + "\\ConsoleSessionConfiguration")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let k = key(params)?
    let present = common::want_present(params)?
    if !policy::switch_converged(policy::current_dword(k, "EnableConsoleSessionConfiguration")?, present) {
        return Ok(CheckResult::NotConfigured)
    }
    if !present { return Ok(CheckResult::AlreadyConfigured) }
    let name = common::param_str(params, "name", "")
    if name == "" {
        return Err("'name' is required when ensure is :present — the policy needs a session configuration to launch the console in")
    }
    // Session configuration names are case-insensitive.
    if policy::current_sz(k, "ConsoleSessionConfigurationName")?.to_lower() != name.to_lower() {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let k = key(params)?
    let present = common::want_present(params)?
    let name = common::param_str(params, "name", "")
    if present && name == "" {
        return Err("'name' is required when ensure is :present — the policy needs a session configuration to launch the console in")
    }
    registry::create_key(k)?
    registry::write(k, "EnableConsoleSessionConfiguration", Value::Int(if present { 1 } else { 0 }), "dword")?
    if present { registry::write(k, "ConsoleSessionConfigurationName", Value::String(name), "sz")? }
    Ok(ApplyResult::Success)
}
