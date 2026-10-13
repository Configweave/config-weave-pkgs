use value
use registry
use common
use policy

fn key(params: Value) -> Result[string, string] {
    Ok(policy::policy_root(common::param_str(params, "edition", "windows_powershell"), registry::HKLM)? + "\\ModuleLogging")
}

// An empty list means the * wildcard, which is how the policy says
// "every module".
fn wanted_modules(params: Value) -> List[string] {
    let names = common::param_list(params, "module_names")
    if names.is_empty() { return ["*"] }
    names
}

// The registry host module reads a value by name and cannot list a key's
// values, so the list is read through Windows PowerShell, which every
// Windows machine has.
fn listed_modules(names_key: string) -> Result[List[string], string] {
    let provider_path = "Registry::" + names_key.replace("HKLM\\", "HKEY_LOCAL_MACHINE\\")
    let script = "$k = " + common::ps_q(provider_path) + "\nif (Test-Path -LiteralPath $k) {{ (Get-Item -LiteralPath $k).GetValueNames() | Where-Object {{ $_ -ne '' }} }}"
    if let Some(text) = common::query("windows_powershell", script)? { return Ok(common::lines_of(text)) }
    Err(common::not_installed("windows_powershell"))
}

fn same_set(a: List[string], b: List[string]) -> bool {
    if a.len() != b.len() { return false }
    let lower: List[string] = []
    for x in b { lower.push(x.to_lower()) }
    for x in a {
        if !lower.contains(x.to_lower()) { return false }
    }
    true
}

fn check(params: Value) -> Result[CheckResult, string] {
    let k = key(params)?
    let present = common::want_present(params)?
    if !policy::switch_converged(policy::current_dword(k, "EnableModuleLogging")?, present) { return Ok(CheckResult::NotConfigured) }
    let names_key = k + "\\ModuleNames"
    let exists = registry::key_exists(names_key)?
    if !present {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !exists { return Ok(CheckResult::NotConfigured) }
    // The list is compared exactly, as a set: an extra name is drift too.
    if !same_set(listed_modules(names_key)?, wanted_modules(params)) { return Ok(CheckResult::NotConfigured) }
    // Each value's data repeats its name — the shape Group Policy writes.
    for name in wanted_modules(params) {
        if policy::current_sz(names_key, name)? != name { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let k = key(params)?
    registry::create_key(k)?
    let present = common::want_present(params)?
    registry::write(k, "EnableModuleLogging", Value::Int(if present { 1 } else { 0 }), "dword")?
    let names_key = k + "\\ModuleNames"
    // Disabling clears the list outright, so a later re-enable does not
    // silently inherit whoever was listed before. Enabling recreates it, so
    // the list ends up exactly `module_names`.
    if registry::key_exists(names_key)? { registry::delete_key(names_key)? }
    if !present { return Ok(ApplyResult::Success) }
    registry::create_key(names_key)?
    for name in wanted_modules(params) {
        registry::write(names_key, name, Value::String(name), "sz")?
    }
    Ok(ApplyResult::Success)
}
