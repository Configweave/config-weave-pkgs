use value
use registry

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn policy_root(params: Value) -> Result[string, string] {
    let edition = param_str(params, "edition", "windows_powershell")
    if edition == "windows_powershell" { return Ok(registry::HKLM + "\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell") }
    if edition == "pwsh" { return Ok(registry::HKLM + "\\SOFTWARE\\Policies\\Microsoft\\PowerShellCore") }
    Err("invalid 'edition' value '" + edition + "' (expected :windows_powershell or :pwsh)")
}

// A missing value reads as -1 so it can never look like a deliberate 0.
fn current_dword(key: string, name: string) -> Result[int, string] {
    if let Some(v) = registry::read(key, name)? {
        if let Some(n) = v.as_int() { return Ok(n) }
    }
    Ok(-1)
}

fn toggle(params: Value, key: string) -> Result[Option[int], string] {
    let want = param_str(params, key, "unmanaged")
    if want == "unmanaged" { return Ok(None) }
    if want == "enabled" { return Ok(Some(1)) }
    if want == "disabled" { return Ok(Some(0)) }
    Err("invalid '" + key + "' value '" + want + "' (expected :enabled, :disabled or :unmanaged)")
}

fn enabled_value(params: Value) -> Result[int, string] {
    if want_present(params)? { return Ok(1) }
    Ok(0)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let key = policy_root(params)? + "\\ScriptBlockLogging"
    if current_dword(key, "EnableScriptBlockLogging")? != enabled_value(params)? {
        return Ok(CheckResult::NotConfigured)
    }
    if let Some(want) = toggle(params, "invocation_logging")? {
        if current_dword(key, "EnableScriptBlockInvocationLogging")? != want {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = policy_root(params)? + "\\ScriptBlockLogging"
    registry::create_key(key)?
    registry::write(key, "EnableScriptBlockLogging", Value::Int(enabled_value(params)?), "dword")?
    if let Some(want) = toggle(params, "invocation_logging")? {
        registry::write(key, "EnableScriptBlockInvocationLogging", Value::Int(want), "dword")?
    }
    Ok(ApplyResult::Success)
}
