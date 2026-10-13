use value
use registry
use common
use policy

// Both editions read this one key, under the Event Logging policy rather
// than either PowerShell policy root.
fn key() -> string {
    registry::HKLM + "\\SOFTWARE\\Policies\\Microsoft\\Windows\\EventLog\\ProtectedEventLogging"
}

// The certificate is a MULTI_SZ, since the policy accepts a list.
fn current_certificate(k: string) -> Result[string, string] {
    if let Some(v) = registry::read(k, "EncryptionCertificate")? {
        if let Some(s) = v.as_string() { return Ok(s) }
        if let Some(items) = v.as_list() {
            let lines: List[string] = []
            for item in items { lines.push(item.as_string().unwrap_or("")) }
            return Ok(lines.join("\n"))
        }
    }
    Ok("")
}

// PEM text arrives as one string; the MULTI_SZ holds one line per entry.
fn certificate_lines(cert: string) -> List[Value] {
    let out: List[Value] = []
    for line in cert.replace("\r\n", "\n").trim().split("\n") { out.push(Value::String(line)) }
    out
}

fn check(params: Value) -> Result[CheckResult, string] {
    let k = key()
    let present = common::want_present(params)?
    if !policy::switch_converged(policy::current_dword(k, "EnableProtectedEventLogging")?, present) {
        return Ok(CheckResult::NotConfigured)
    }
    if !present { return Ok(CheckResult::AlreadyConfigured) }
    let cert = common::param_str(params, "encryption_certificate", "")
    if cert == "" {
        return Err("'encryption_certificate' is required when ensure is :present — protected event logging has nothing to encrypt to without one")
    }
    if current_certificate(k)?.trim() != cert.replace("\r\n", "\n").trim() { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let k = key()
    let present = common::want_present(params)?
    let cert = common::param_str(params, "encryption_certificate", "")
    if present && cert == "" {
        return Err("'encryption_certificate' is required when ensure is :present — protected event logging has nothing to encrypt to without one")
    }
    registry::create_key(k)?
    registry::write(k, "EnableProtectedEventLogging", Value::Int(if present { 1 } else { 0 }), "dword")?
    if present { registry::write(k, "EncryptionCertificate", Value::List(certificate_lines(cert)), "multi_sz")? }
    Ok(ApplyResult::Success)
}
