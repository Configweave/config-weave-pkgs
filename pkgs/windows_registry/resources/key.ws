use value
use shell
use registry
use json
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) {
        if let Some(s) = v.as_string() { return s }
    }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let items: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs {
                if let Some(s) = x.as_string() { items.push(s) }
            }
        }
    }
    items
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

// Hive-prefixed key → a PowerShell Registry:: provider path (works for all
// hives, unlike the HKLM:/HKCU: drives).
fn ps_reg_path(key: string) -> Result[string, string] {
    if key.starts_with("HKLM\\") { return Ok("Registry::HKEY_LOCAL_MACHINE\\" + key.slice(5, key.len())) }
    if key.starts_with("HKCU\\") { return Ok("Registry::HKEY_CURRENT_USER\\" + key.slice(5, key.len())) }
    if key.starts_with("HKCR\\") { return Ok("Registry::HKEY_CLASSES_ROOT\\" + key.slice(5, key.len())) }
    if key.starts_with("HKU\\") { return Ok("Registry::HKEY_USERS\\" + key.slice(4, key.len())) }
    if key.starts_with("HKCC\\") { return Ok("Registry::HKEY_CURRENT_CONFIG\\" + key.slice(5, key.len())) }
    Err("key must be hive-prefixed (HKLM\\, HKCU\\, HKCR\\, HKU\\ or HKCC\\): " + key)
}

// One "identity:rights" spec → [identity, rights]. rights is a
// System.Security.AccessControl.RegistryRights name (FullControl, ReadKey, …).
fn perm_parts(spec: string) -> Result[List[string], string] {
    if let Some(i) = spec.find(":") {
        let ident = spec.slice(0, i).trim()
        let rights = spec.slice(i + 1, spec.len()).trim()
        if ident != "" && rights != "" { return Ok([ident, rights]) }
    }
    Err("invalid permission '" + spec + "' (expected \"identity:rights\", e.g. \"BUILTIN\\Users:ReadKey\")")
}

// PowerShell that emits the key's ACL as one JSON object:
// { owner, rules: [{ identity, rights, type }] }.
fn acl_ps(path: string) -> string {
    "$ErrorActionPreference='Stop'; " +
    "$acl = Get-Acl -Path " + ps_q(path) + "; " +
    "[pscustomobject]@{{ " +
        "owner = \"$($acl.Owner)\"; " +
        "rules = @($acl.Access | ForEach-Object {{ [pscustomobject]@{{ " +
            "identity = \"$($_.IdentityReference)\"; " +
            "rights = \"$($_.RegistryRights)\"; " +
            "type = \"$($_.AccessControlType)\" " +
        "}} }}) " +
    "}} | ConvertTo-Json -Compress -Depth 4"
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

// The ACL's rules as a list whether JSON carried a list or a single
// collapsed object (ConvertTo-Json in Windows PowerShell 5.1).
fn acl_rules(acl: Value) -> List[Value] {
    let rules = []
    if let Some(v) = acl.get("rules") {
        if let Some(items) = v.as_list() {
            for item in items { rules.push(item) }
        } else if let Some(single) = v.as_map() {
            rules.push(Value::Map(single))
        }
    }
    rules
}

// An Allow rule for `ident` whose (possibly composite) rights string lists
// `right` as one of its flags. Literal flag matching: FullControl does not
// satisfy a ReadKey spec.
fn rule_grants(rule: Value, ident: string, right: string) -> bool {
    if get_str(rule, "type") != "Allow" { return false }
    if get_str(rule, "identity").to_lower() != ident.to_lower() { return false }
    for tok in get_str(rule, "rights").split(",") {
        if tok.trim().to_lower() == right.to_lower() { return true }
    }
    false
}

fn read_acl(key: string) -> Result[Value, string] {
    let out = shell::powershell(acl_ps(ps_reg_path(key)?), Value::Null)?
    if !out.success { return Err("reading ACL of " + key + " failed: " + out.stderr.trim()) }
    json::parse(out.stdout.trim())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let key = param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    let exists = registry::key_exists(key)?
    if !want_present(params)? {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !exists { return Ok(CheckResult::NotConfigured) }
    let owner = param_str(params, "owner", "")
    let perms = param_list(params, "permissions")
    if owner == "" && perms.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    let acl = read_acl(key)?
    if owner != "" && get_str(acl, "owner").to_lower() != owner.to_lower() {
        return Ok(CheckResult::NotConfigured)
    }
    let rules = acl_rules(acl)
    for spec in perms {
        let parts = perm_parts(spec)?
        let ident = parts.get(0).unwrap_or("")
        let right = parts.get(1).unwrap_or("")
        let hit = [false]
        for rule in rules {
            if rule_grants(rule, ident, right) { hit.set(0, true) }
        }
        if !hit.get(0).unwrap_or(false) { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = param_str(params, "key", "")
    if key == "" { return Err("missing 'key' parameter") }
    if !want_present(params)? {
        if registry::key_exists(key)? {
            log::info("deleting registry key " + key)
            registry::delete_key(key)?
        }
        return Ok(ApplyResult::Success)
    }
    if !registry::key_exists(key)? {
        log::info("creating registry key " + key)
        registry::create_key(key)?
    }
    let owner = param_str(params, "owner", "")
    let perms = param_list(params, "permissions")
    if owner == "" && perms.is_empty() { return Ok(ApplyResult::Success) }
    let parts = ["$ErrorActionPreference='Stop'; $path = " + ps_q(ps_reg_path(key)?) + "; $acl = Get-Acl -Path $path; "]
    if owner != "" {
        parts.push("$acl.SetOwner([System.Security.Principal.NTAccount]" + ps_q(owner) + "); ")
    }
    for spec in perms {
        let pp = perm_parts(spec)?
        parts.push(
            "$rule = New-Object System.Security.AccessControl.RegistryAccessRule(" +
            ps_q(pp.get(0).unwrap_or("")) + ", " + ps_q(pp.get(1).unwrap_or("")) +
            ", 'ContainerInherit,ObjectInherit', 'None', 'Allow'); " +
            "$acl.AddAccessRule($rule); "
        )
    }
    parts.push("Set-Acl -Path $path -AclObject $acl")
    let out = shell::powershell(parts.join(""), Value::Null)?
    if !out.success { return Err("setting ACL of " + key + " failed: " + out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
