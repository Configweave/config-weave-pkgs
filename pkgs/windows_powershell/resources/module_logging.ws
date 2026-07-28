use value
use registry

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let out: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(items) = v.as_list() {
            for item in items {
                if let Some(s) = item.as_string() { out.push(s) }
            }
        }
    }
    out
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

// An empty list means the * wildcard, which is how the policy says
// "every module".
fn wanted_modules(params: Value) -> List[string] {
    if !want_present(params).unwrap_or(true) {
        let none: List[string] = []
        return none
    }
    let names = param_list(params, "module_names")
    if names.is_empty() { return ["*"] }
    names
}

fn check(params: Value) -> Result[CheckResult, string] {
    let root = policy_root(params)?
    let key = root + "\\ModuleLogging"
    let enabled = if want_present(params)? { 1 } else { 0 }
    if current_dword(key, "EnableModuleLogging")? != enabled { return Ok(CheckResult::NotConfigured) }

    // Each module is its own value under ModuleNames, whose data repeats the
    // name — that is the shape Group Policy writes.
    let names_key = key + "\\ModuleNames"
    let wanted = wanted_modules(params)
    if !registry::key_exists(names_key)? { return Ok(if wanted.is_empty() { CheckResult::AlreadyConfigured } else { CheckResult::NotConfigured }) }
    for name in wanted {
        if let Some(v) = registry::read(names_key, name)? {
            if v.as_string().unwrap_or("") != name { return Ok(CheckResult::NotConfigured) }
        } else {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let root = policy_root(params)?
    let key = root + "\\ModuleLogging"
    registry::create_key(key)?
    let present = want_present(params)?
    registry::write(key, "EnableModuleLogging", Value::Int(if present { 1 } else { 0 }), "dword")?
    let names_key = key + "\\ModuleNames"
    if !present {
        // Disabling clears the list outright, so a later re-enable does not
        // silently inherit whoever was listed before.
        if registry::key_exists(names_key)? { registry::delete_key(names_key)? }
        return Ok(ApplyResult::Success)
    }
    // Recreated rather than merged, so the list ends up exactly `wanted`.
    // (`check` can only prove the wanted names are present: the registry host
    // module reads a value by name and cannot enumerate a key's values.)
    if registry::key_exists(names_key)? { registry::delete_key(names_key)? }
    registry::create_key(names_key)?
    for name in wanted_modules(params) {
        registry::write(names_key, name, Value::String(name), "sz")?
    }
    Ok(ApplyResult::Success)
}
