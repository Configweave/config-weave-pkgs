use value
use registry
use common
use policy

fn key(params: Value) -> Result[string, string] {
    Ok(policy::policy_root(common::param_str(params, "edition", "windows_powershell"), registry::HKLM)? + "\\Transcription")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let k = key(params)?
    if !policy::switch_converged(policy::current_dword(k, "EnableTranscripting")?, common::want_present(params)?) {
        return Ok(CheckResult::NotConfigured)
    }
    let dir = common::param_str(params, "output_directory", "")
    // A directory is a Windows path: compared case-insensitively.
    if dir != "" && policy::current_sz(k, "OutputDirectory")?.to_lower() != dir.to_lower() { return Ok(CheckResult::NotConfigured) }
    if let Some(want) = policy::toggle(common::param_str(params, "invocation_header", "unmanaged"), "invocation_header")? {
        if policy::current_dword(k, "EnableInvocationHeader")? != want { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let k = key(params)?
    registry::create_key(k)?
    registry::write(k, "EnableTranscripting", Value::Int(if common::want_present(params)? { 1 } else { 0 }), "dword")?
    let dir = common::param_str(params, "output_directory", "")
    if dir != "" { registry::write(k, "OutputDirectory", Value::String(dir), "sz")? }
    if let Some(want) = policy::toggle(common::param_str(params, "invocation_header", "unmanaged"), "invocation_header")? {
        registry::write(k, "EnableInvocationHeader", Value::Int(want), "dword")?
    }
    Ok(ApplyResult::Success)
}
