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

fn current_dword(key: string, name: string) -> Result[int, string] {
    if let Some(v) = registry::read(key, name)? {
        if let Some(n) = v.as_int() { return Ok(n) }
    }
    Ok(-1)
}

fn current_sz(key: string, name: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, name)? {
        if let Some(s) = v.as_string() { return Ok(s) }
    }
    Ok("")
}

fn toggle(params: Value, key: string) -> Result[Option[int], string] {
    let want = param_str(params, key, "unmanaged")
    if want == "unmanaged" { return Ok(None) }
    if want == "enabled" { return Ok(Some(1)) }
    if want == "disabled" { return Ok(Some(0)) }
    Err("invalid '" + key + "' value '" + want + "' (expected :enabled, :disabled or :unmanaged)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let key = policy_root(params)? + "\\Transcription"
    let enabled = if want_present(params)? { 1 } else { 0 }
    if current_dword(key, "EnableTranscripting")? != enabled { return Ok(CheckResult::NotConfigured) }
    let dir = param_str(params, "output_directory", "")
    if dir != "" && current_sz(key, "OutputDirectory")? != dir { return Ok(CheckResult::NotConfigured) }
    if let Some(want) = toggle(params, "invocation_header")? {
        if current_dword(key, "EnableInvocationHeader")? != want { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = policy_root(params)? + "\\Transcription"
    registry::create_key(key)?
    registry::write(key, "EnableTranscripting", Value::Int(if want_present(params)? { 1 } else { 0 }), "dword")?
    let dir = param_str(params, "output_directory", "")
    if dir != "" { registry::write(key, "OutputDirectory", Value::String(dir), "sz")? }
    if let Some(want) = toggle(params, "invocation_header")? {
        registry::write(key, "EnableInvocationHeader", Value::Int(want), "dword")?
    }
    Ok(ApplyResult::Success)
}
