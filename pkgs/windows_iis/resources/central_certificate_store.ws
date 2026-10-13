use value
use log
use registry
use common

// ---------------------------------------------------------------------------
// The IIS central certificate store.
//
// State is read from the registry rather than through
// Get-WebCentralCertProvider: the cmdlet exists, but it does not return the
// credentials, and the registry answer for the two things that ARE readable —
// whether the provider is enabled and where its store is — is the same one the
// provider itself reads.
//
// The credentials really are write-only: IIS stores them encrypted and will not
// hand them back. So they are applied when the provider is enabled and cannot
// be converged afterwards. To rotate them, disable and re-enable, or call
// Set-WebCentralCertProvider out of band.
//
// Caveat: the registry key this reads is not documented on learn.microsoft.com.
// It is what the provider uses today, but it is not a promised contract.
// ---------------------------------------------------------------------------

fn provider_key() -> string { "HKLM\\SOFTWARE\\Microsoft\\IIS\\CentralCertProvider" }

// { enabled, cert_store_location }; enabled is false when the key is absent.
fn probe() -> Result[Value, string] {
    if !registry::key_exists(provider_key())? {
        return Ok(Value::Map(#{
            "enabled": Value::Bool(false),
            "cert_store_location": Value::String(""),
        }))
    }
    let on = false
    if let Some(v) = registry::read(provider_key(), "Enabled")? {
        if let Some(i) = v.as_int() { on = i != 0 }
        if let Some(b) = v.as_bool() { on = b }
    }
    let loc = ""
    if let Some(v) = registry::read(provider_key(), "CertStoreLocation")? {
        if let Some(s) = v.as_string() { loc = s }
    }
    Ok(Value::Map(#{
        "enabled": Value::Bool(on),
        "cert_store_location": Value::String(loc),
    }))
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

fn norm_path(p: string) -> string {
    let s = p.replace("/", "\\").to_lower()
    if s.len() > 1 && s.ends_with("\\") { return s.slice(0, s.len() - 1) }
    s
}

fn check(params: Value) -> Result[CheckResult, string] {
    let now = probe()?
    if common::has(params, "enabled") {
        if get_bool(now, "enabled") != common::param_bool(params, "enabled", false) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    let loc = common::param_str(params, "cert_store_location", "")
    if loc != "" && norm_path(common::get_str(now, "cert_store_location")) != norm_path(loc) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let now = probe()?
    let want_on = if common::has(params, "enabled") {
        common::param_bool(params, "enabled", false)
    } else {
        get_bool(now, "enabled")
    }
    if !want_on {
        if !get_bool(now, "enabled") { return Ok(ApplyResult::Success) }
        log::info("disabling the central certificate store")
        common::ps_run("Disable-WebCentralCertProvider")?
        return Ok(ApplyResult::Success)
    }
    let loc = common::param_str(params, "cert_store_location", "")
    if loc == "" { return Err("'cert_store_location' is required to enable the central certificate store") }
    let user = common::param_str(params, "username", "")
    let password = common::param_str(params, "password", "")
    // Enable-WebCentralCertProvider marks CertStoreLocation, UserName and
    // Password all Mandatory. Omitting one makes PowerShell prompt, which in a
    // non-interactive host is a terminating error rather than a default.
    if user == "" || password == "" {
        return Err("'username' and 'password' are both required to enable the central certificate store")
    }
    let user_arg = " -UserName " + common::ps_q(user)
    // Plain strings: Enable-WebCentralCertProvider declares -Password and
    // -PrivateKeyPassword as [String], not [SecureString]. Handing it a
    // SecureString stores the literal text "System.Security.SecureString".
    let pw_arg = " -Password " + common::ps_q(password)
    let pk = common::param_str(params, "private_key_password", "")
    let pk_arg = if pk == "" { "" } else { " -PrivateKeyPassword " + common::ps_q(pk) }
    log::info("enabling the central certificate store at " + loc)
    common::ps_run("Enable-WebCentralCertProvider -CertStoreLocation " + common::ps_q(loc) +
        user_arg + pw_arg + pk_arg)?
    Ok(ApplyResult::Success)
}
