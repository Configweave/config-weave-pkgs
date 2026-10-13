use value
use log
use registry
use hash
use time
use env
use common

// ---------------------------------------------------------------------------
// The IIS central certificate store.
//
// State is read from the registry rather than through
// Get-WebCentralCertProvider, which masks what it returns; the registry
// answer for what IS readable — whether the provider is enabled, where its
// store is and the account that reads it — is the one the provider itself
// reads.
//
// The two passwords are stored encrypted and cannot be read back. So that a
// changed password is still noticed, this resource records a salted SHA-256
// of the passwords it last wrote under HKLM\SOFTWARE\ConfigWeave\windows_iis
// and compares against that. A password changed outside config-weave is not
// detected; the next change made here overwrites it.
//
// Caveat: the provider's registry key is not documented on
// learn.microsoft.com. It is what the provider uses today, but it is not a
// promised contract.
// ---------------------------------------------------------------------------

fn provider_key() -> string { "HKLM\\SOFTWARE\\Microsoft\\IIS\\CentralCertProvider" }

fn state_key() -> string { "HKLM\\SOFTWARE\\ConfigWeave\\windows_iis" }

fn read_str(key: string, name: string) -> Result[string, string] {
    if !registry::key_exists(key)? { return Ok("") }
    if let Some(v) = registry::read(key, name)? {
        if let Some(s) = v.as_string() { return Ok(s) }
    }
    Ok("")
}

// { enabled, cert_store_location, username }; enabled is false when the key
// is absent.
fn probe() -> Result[Value, string] {
    let on = false
    if registry::key_exists(provider_key())? {
        if let Some(v) = registry::read(provider_key(), "Enabled")? {
            if let Some(i) = v.as_int() { on = i != 0 }
            if let Some(b) = v.as_bool() { on = b }
        }
    }
    Ok(Value::Map(#{
        "enabled": Value::Bool(on),
        "cert_store_location": Value::String(read_str(provider_key(), "CertStoreLocation")?),
        "username": Value::String(read_str(provider_key(), "UserName")?),
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

fn secret_hash(salt: string, params: Value) -> string {
    hash::sha256(salt + "\n" + common::param_str(params, "password", "") + "\n" +
        common::param_str(params, "private_key_password", ""))
}

fn secrets_match(params: Value) -> Result[bool, string] {
    let salt = read_str(state_key(), "CcsSalt")?
    if salt == "" { return Ok(false) }
    Ok(read_str(state_key(), "CcsSecretHash")? == secret_hash(salt, params))
}

// Whether the step asks for the provider on. A location implies it, so a step
// naming one while the provider is off converges by enabling it rather than
// reporting drift for ever; enabled = false with a location is refused.
fn want_on(params: Value) -> Result[Option[bool], string] {
    let loc = common::param_str(params, "cert_store_location", "")
    if common::has(params, "enabled") {
        let on = common::param_bool(params, "enabled", false)
        if !on && loc != "" { return Err("'cert_store_location' cannot be set with enabled = false") }
        return Ok(Some(on))
    }
    if loc != "" { return Ok(Some(true)) }
    Ok(None)
}

fn validate_on(params: Value) -> Result[unit, string] {
    if common::param_str(params, "cert_store_location", "") == "" {
        return Err("'cert_store_location' is required to enable the central certificate store")
    }
    // Enable-WebCentralCertProvider marks CertStoreLocation, UserName and
    // Password all Mandatory. Omitting one makes PowerShell prompt, which in a
    // non-interactive host is a terminating error rather than a default.
    if common::param_str(params, "username", "") == "" || common::param_str(params, "password", "") == "" {
        return Err("'username' and 'password' are both required to enable the central certificate store")
    }
    Ok(())
}

fn converged(params: Value, now: Value) -> Result[bool, string] {
    let on = want_on(params)?
    if on.is_none() { return Ok(true) }
    let on = on.unwrap_or(false)
    if get_bool(now, "enabled") != on { return Ok(false) }
    if !on { return Ok(true) }
    validate_on(params)?
    if norm_path(common::get_str(now, "cert_store_location")) != norm_path(common::param_str(params, "cert_store_location", "")) {
        return Ok(false)
    }
    if common::get_str(now, "username").to_lower() != common::param_str(params, "username", "").to_lower() { return Ok(false) }
    secrets_match(params)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if converged(params, probe()?)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let now = probe()?
    if converged(params, now)? { return Ok(ApplyResult::Success) }
    if !want_on(params)?.unwrap_or(false) {
        log::info("disabling the central certificate store")
        common::ps_run("Disable-WebCentralCertProvider")?
        return Ok(ApplyResult::Success)
    }
    let loc = common::param_str(params, "cert_store_location", "")
    // Plain strings: Enable-WebCentralCertProvider declares -Password and
    // -PrivateKeyPassword as [String], not [SecureString]. Handing it a
    // SecureString stores the literal text "System.Security.SecureString".
    // Both travel in the environment, never in the script text.
    let pk = common::param_str(params, "private_key_password", "")
    let pk_arg = if pk == "" { "" } else { " -PrivateKeyPassword $env:CW_SECRET_PK" }
    log::info("enabling the central certificate store at " + loc)
    common::ps_run_env("Enable-WebCentralCertProvider -CertStoreLocation " + common::ps_q(loc) +
        " -UserName " + common::ps_q(common::param_str(params, "username", "")) +
        " -Password $env:CW_SECRET" + pk_arg,
        Value::Map(#{
            "CW_SECRET": Value::String(common::param_str(params, "password", "")),
            "CW_SECRET_PK": Value::String(pk),
        }))?
    let salt = hash::sha256(env::hostname() + common::itoa(time::now_millis()))
    registry::create_key(state_key())?
    registry::write(state_key(), "CcsSalt", Value::String(salt), "sz")?
    registry::write(state_key(), "CcsSecretHash", Value::String(secret_hash(salt, params)), "sz")?
    Ok(ApplyResult::Success)
}
