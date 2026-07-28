use value
use registry

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn pascal(symbol: string) -> string {
    let out = ""
    for word in symbol.split("_") {
        if word != "" { out = out + word.slice(0, 1).to_upper() + word.slice(1, word.len()) }
    }
    out
}

// Windows PowerShell 5.1 reads ...\Policies\Microsoft\Windows\PowerShell;
// PowerShell 7 reads ...\Policies\Microsoft\PowerShellCore.
fn policy_key(edition: string, hive: string) -> Result[string, string] {
    if edition == "windows_powershell" { return Ok(hive + "\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell") }
    if edition == "pwsh" { return Ok(hive + "\\SOFTWARE\\Policies\\Microsoft\\PowerShellCore") }
    Err("invalid 'edition' value '" + edition + "' (expected :windows_powershell or :pwsh)")
}

// The two preference scopes are not Group Policy: they live under the shell
// id, which is where Set-ExecutionPolicy writes them.
fn preference_key(hive: string) -> string {
    hive + "\\SOFTWARE\\Microsoft\\PowerShell\\1\\ShellIds\\Microsoft.PowerShell"
}

fn target_key(params: Value) -> Result[string, string] {
    let scope = param_str(params, "scope", "local_machine")
    let edition = param_str(params, "edition", "windows_powershell")
    if scope == "machine_policy" { return policy_key(edition, registry::HKLM) }
    if scope == "user_policy" { return policy_key(edition, registry::HKCU) }
    if scope == "local_machine" { return Ok(preference_key(registry::HKLM)) }
    if scope == "current_user" { return Ok(preference_key(registry::HKCU)) }
    Err("invalid 'scope' value '" + scope + "' (expected :machine_policy, :user_policy, :local_machine or :current_user)")
}

fn current_policy(key: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, "ExecutionPolicy")? {
        if let Some(s) = v.as_string() { return Ok(s) }
    }
    Ok("")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let wanted = param_str(params, "policy", "")
    if wanted == "" { return Err("missing 'policy' parameter") }
    let current = current_policy(target_key(params)?)?
    // :undefined is the absence of a value, not a value of "Undefined".
    if wanted == "undefined" {
        if current == "" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if current == pascal(wanted) { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let wanted = param_str(params, "policy", "")
    if wanted == "" { return Err("missing 'policy' parameter") }
    let key = target_key(params)?
    if wanted == "undefined" {
        if registry::key_exists(key)? {
            if let Some(_existing) = registry::read(key, "ExecutionPolicy")? {
                registry::delete_value(key, "ExecutionPolicy")?
            }
        }
        return Ok(ApplyResult::Success)
    }
    registry::write(key, "ExecutionPolicy", Value::String(pascal(wanted)), "sz")?
    Ok(ApplyResult::Success)
}
