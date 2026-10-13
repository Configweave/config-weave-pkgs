use value
use registry
use common
use policy

fn key(params: Value) -> Result[string, string] {
    Ok(policy::policy_root(common::param_str(params, "edition", "windows_powershell"), registry::HKLM)? + "\\ScriptBlockLogging")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let k = key(params)?
    if !policy::switch_converged(policy::current_dword(k, "EnableScriptBlockLogging")?, common::want_present(params)?) {
        return Ok(CheckResult::NotConfigured)
    }
    if let Some(want) = policy::toggle(common::param_str(params, "invocation_logging", "unmanaged"), "invocation_logging")? {
        if policy::current_dword(k, "EnableScriptBlockInvocationLogging")? != want {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let k = key(params)?
    registry::create_key(k)?
    registry::write(k, "EnableScriptBlockLogging", Value::Int(if common::want_present(params)? { 1 } else { 0 }), "dword")?
    if let Some(want) = policy::toggle(common::param_str(params, "invocation_logging", "unmanaged"), "invocation_logging")? {
        registry::write(k, "EnableScriptBlockInvocationLogging", Value::Int(want), "dword")?
    }
    Ok(ApplyResult::Success)
}
