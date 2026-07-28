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

// The certificate is a MULTI_SZ, since the policy accepts a list.
fn current_certificate(key: string) -> Result[string, string] {
    if let Some(v) = registry::read(key, "EncryptionCertificate")? {
        if let Some(s) = v.as_string() { return Ok(s) }
        if let Some(items) = v.as_list() {
            if let Some(first) = items.get(0) { return Ok(first.as_string().unwrap_or("")) }
        }
    }
    Ok("")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let key = policy_root(params)? + "\\ProtectedEventLogging"
    let present = want_present(params)?
    let enabled = if present { 1 } else { 0 }
    // A key that was never written reads -1, which is the state a stock
    // machine is in — and that already satisfies ensure = :absent.
    let current = current_dword(key, "EnableProtectedEventLogging")?
    if !present {
        if current == 0 || current == -1 { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if current != enabled { return Ok(CheckResult::NotConfigured) }
    let cert = param_str(params, "encryption_certificate", "")
    if cert != "" && current_certificate(key)? != cert { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = policy_root(params)? + "\\ProtectedEventLogging"
    let present = want_present(params)?
    let cert = param_str(params, "encryption_certificate", "")
    if present && cert == "" {
        return Err("'encryption_certificate' is required when ensure is :present — protected event logging has nothing to encrypt to without one")
    }
    registry::create_key(key)?
    registry::write(key, "EnableProtectedEventLogging", Value::Int(if present { 1 } else { 0 }), "dword")?
    if present { registry::write(key, "EncryptionCertificate", Value::List([Value::String(cert)]), "multi_sz")? }
    Ok(ApplyResult::Success)
}
