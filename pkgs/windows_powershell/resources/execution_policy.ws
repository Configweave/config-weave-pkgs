use value
use registry
use json
use common
use config_file
use policy

// The two preference scopes are not Group Policy. Windows PowerShell 5.1
// keeps them under its shell id in the registry, which is where its
// Set-ExecutionPolicy writes them. PowerShell 7 never reads that key: it
// keeps them in powershell.config.json — $PSHOME's for LocalMachine, the
// user's for CurrentUser.
fn preference_key(hive: string) -> string {
    hive + "\\SOFTWARE\\Microsoft\\PowerShell\\1\\ShellIds\\Microsoft.PowerShell"
}

fn config_key() -> string { "Microsoft.PowerShell:ExecutionPolicy" }

fn scope(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "scope", "local_machine")
    let valid = ["machine_policy", "user_policy", "local_machine", "current_user"]
    if !valid.contains(s) { return Err("invalid 'scope' value '" + s + "' (expected :machine_policy, :user_policy, :local_machine or :current_user)") }
    Ok(s)
}

fn edition(params: Value) -> Result[string, string] {
    let e = common::param_str(params, "edition", "windows_powershell")
    if e != "windows_powershell" && e != "pwsh" { return Err("invalid 'edition' value '" + e + "' (expected :windows_powershell or :pwsh)") }
    Ok(e)
}

// True when this scope lives in powershell.config.json rather than the
// registry.
fn in_config_file(params: Value) -> Result[bool, string] {
    let s = scope(params)?
    Ok(edition(params)? == "pwsh" && (s == "local_machine" || s == "current_user"))
}

fn registry_key(params: Value) -> Result[string, string] {
    let s = scope(params)?
    if s == "machine_policy" { return policy::policy_root(edition(params)?, registry::HKLM) }
    if s == "user_policy" { return policy::policy_root(edition(params)?, registry::HKCU) }
    if s == "local_machine" { return Ok(preference_key(registry::HKLM)) }
    Ok(preference_key(registry::HKCU))
}

fn config_scope(params: Value) -> Result[string, string] {
    if scope(params)? == "local_machine" { return Ok("all_users") }
    Ok("current_user")
}

fn wanted_policy(params: Value) -> Result[Option[string], string] {
    if !common::want_present(params)? { return Ok(None) }
    let p = common::param_str(params, "policy", "")
    if p == "" { return Err("'policy' is required when ensure is :present") }
    Ok(Some(common::pascal(p)))
}

// "" when no policy is set. None when the configuration file cannot be
// resolved because PowerShell 7 is not installed yet.
fn current_policy(params: Value) -> Result[Option[string], string] {
    if in_config_file(params)? {
        let file = config_file::config_path_for(params, config_scope(params)?)?
        if file.is_none() { return Ok(None) }
        let doc = config_file::read_doc(config_file::user_root_for(params, config_scope(params)?), file.unwrap())?
        if let Some(v) = doc.get(config_key()) { return Ok(Some(v.as_string().unwrap_or(json::to_string(v)))) }
        return Ok(Some(""))
    }
    Ok(Some(policy::current_sz(registry_key(params)?, "ExecutionPolicy")?))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let wanted = wanted_policy(params)?
    let current = current_policy(params)?
    if current.is_none() {
        if wanted.is_some() { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    let have = current.unwrap()
    // Windows compares policy names case-insensitively, and so does this.
    if let Some(want) = wanted {
        if have.to_lower() == want.to_lower() { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if have == "" { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let wanted = wanted_policy(params)?
    if in_config_file(params)? {
        let resolved = config_file::config_path_for(params, config_scope(params)?)?
        if resolved.is_none() { return Err("cannot resolve powershell.config.json: " + common::not_installed("pwsh")) }
        let file = resolved.unwrap()
        let root = config_file::user_root_for(params, config_scope(params)?)
        let doc = config_file::read_doc(root, file)?
        let updated = if let Some(want) = wanted { config_file::put(doc, config_key(), Value::String(want)) } else { config_file::drop_key(doc, config_key()) }
        config_file::write_doc(root, file, updated)?
        return Ok(ApplyResult::Success)
    }
    let key = registry_key(params)?
    if let Some(want) = wanted {
        registry::write(key, "ExecutionPolicy", Value::String(want), "sz")?
        return Ok(ApplyResult::Success)
    }
    if registry::key_exists(key)? {
        if let Some(_existing) = registry::read(key, "ExecutionPolicy")? {
            registry::delete_value(key, "ExecutionPolicy")?
        }
    }
    Ok(ApplyResult::Success)
}
