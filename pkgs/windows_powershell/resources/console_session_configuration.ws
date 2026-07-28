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

fn check(params: Value) -> Result[CheckResult, string] {
    let key = policy_root(params)? + "\\ConsoleSessionConfiguration"
    let present = want_present(params)?
    let current = current_dword(key, "EnableConsoleSessionConfiguration")?
    if !present {
        if current == 0 || current == -1 { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if current != 1 { return Ok(CheckResult::NotConfigured) }
    let name = param_str(params, "name", "")
    if name != "" && current_sz(key, "ConsoleSessionConfigurationName")? != name {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = policy_root(params)? + "\\ConsoleSessionConfiguration"
    let present = want_present(params)?
    let name = param_str(params, "name", "")
    if present && name == "" {
        return Err("'name' is required when ensure is :present — the policy needs a session configuration to launch the console in")
    }
    registry::create_key(key)?
    registry::write(key, "EnableConsoleSessionConfiguration", Value::Int(if present { 1 } else { 0 }), "dword")?
    if present { registry::write(key, "ConsoleSessionConfigurationName", Value::String(name), "sz")? }
    Ok(ApplyResult::Success)
}
