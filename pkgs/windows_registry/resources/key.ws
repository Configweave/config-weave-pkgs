use value
use log
use registry
use common
use acl
use access

// Keys an :absent step may never delete, below the hive (compared
// case-insensitively). Everything one segment below a hive is refused too.
fn protected_keys(hive: string) -> List[string] {
    if hive == "LocalMachine" {
        return ["software\\microsoft", "software\\classes", "software\\policies", "software\\wow6432node",
                "software\\wow6432node\\microsoft", "software\\wow6432node\\classes",
                "system\\currentcontrolset", "system\\controlset001", "system\\controlset002", "system\\setup",
                "system\\mounteddevices", "system\\select"]
    }
    if hive == "CurrentUser" {
        return ["software\\microsoft", "software\\classes", "software\\policies", "control panel", "environment"]
    }
    []
}

// :absent deletes a whole subtree, so it refuses a hive root, anything one
// segment below a hive (HKLM\Software, HKCU\Software, HKLM\SYSTEM, ...), a
// user's hive root under HKU and the well-known system keys.
fn guard_delete(key: string, hive: string, sub: string) -> Result[unit, string] {
    let segs = sub.split("\\")
    let rel = sub.to_lower()
    let check_hive = hive
    let min = 2
    if hive == "Users" {
        // HKU\<sid>\... is that user's HKCU.
        min = 3
        check_hive = "CurrentUser"
        rel = segs.slice(1, segs.len()).join("\\").to_lower()
    }
    if segs.len() < min {
        return Err("refusing to delete '" + key + "': :absent needs a key at least " + str(min) + " segments below the hive")
    }
    for p in protected_keys(check_hive) {
        if rel == p { return Err("refusing to delete '" + key + "': it is a system key") }
    }
    Ok(())
}

fn mode_exact(params: Value) -> Result[bool, string] {
    let m = common::param_str(params, "permissions_mode", "additive")
    if m == "additive" { return Ok(false) }
    if m == "exact" { return Ok(true) }
    Err("invalid 'permissions_mode' value '" + m + "' (expected :additive or :exact)")
}

// The host acl module's options for this key: a registry target in the
// chosen view.
fn acl_opts(params: Value) -> Result[Value, string] {
    let v = common::param_str(params, "view", "native")
    common::view_member(params)?
    Ok(Value::Map(#{ "target": Value::String("registry"), "view": Value::String(v) }))
}

// Rules are written to apply to the key and all subkeys.
fn flags() -> List[string] { ["container"] }

fn validate_perms(perms: List[string]) -> Result[unit, string] {
    for spec in perms {
        let pp = access::spec_parts(spec)?
        access::parse_rights("registry", pp.get(0).unwrap_or(""), pp.get(1).unwrap_or(""))?
    }
    Ok(())
}

// The drift between the key's owner and explicit rules and the wanted
// ones, and the rules to write when there is any (see lib/access.ws).
fn evaluate(hkey: string, aopts: Value, owner: string, perms: List[string], exact: bool) -> Result[List[string], string] {
    let want_owner = if owner != "" { access::sid_of(owner)? } else { "" }
    let wants = access::wanted("registry", perms, [], flags())?
    let cur = access::current("registry", hkey, aopts, true)?
    let drift = if perms.is_empty() && !exact { [] } else { access::drift(cur, wants, exact, false) }
    if want_owner != "" && cur.owner != want_owner { drift.push("owner is " + cur.owner + ", wanted " + want_owner) }
    Ok(drift)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let key = common::param_str(params, "key", "")
    let parts = common::split_key(key, 1)?
    let hive = parts.get(0).unwrap_or("")
    let sub = parts.get(1).unwrap_or("")
    let view = common::view_member(params)?
    let opts = common::view_opts(params)?
    let present = common::want_present(params)?
    let owner = common::param_str(params, "owner", "")
    let perms = common::param_strs(params, "permissions")
    let exact = mode_exact(params)?
    if !present { guard_delete(key, hive, sub)? }
    let managed = present && (owner != "" || !perms.is_empty() || exact)
    let aopts = acl_opts(params)?
    if managed { validate_perms(perms)? }
    let exists = registry::key_exists_with(common::host_key(hive, sub), opts)?
    if !present {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !exists { return Ok(CheckResult::NotConfigured) }
    if !managed { return Ok(CheckResult::AlreadyConfigured) }
    let drift = evaluate(common::host_key(hive, sub), aopts, owner, perms, exact)?
    if !drift.is_empty() {
        for d in drift { log::info(key + ": " + d) }
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let key = common::param_str(params, "key", "")
    let parts = common::split_key(key, 1)?
    let hive = parts.get(0).unwrap_or("")
    let sub = parts.get(1).unwrap_or("")
    let view = common::view_member(params)?
    let opts = common::view_opts(params)?
    let hkey = common::host_key(hive, sub)
    if !common::want_present(params)? {
        guard_delete(key, hive, sub)?
        if !registry::key_exists_with(hkey, opts)? { return Ok(ApplyResult::Success) }
        log::info("deleting registry key " + key + " and its subtree")
        registry::delete_key_with(hkey, opts)?
        return Ok(ApplyResult::Success)
    }
    log::info("ensuring registry key " + key)
    registry::create_key_with(hkey, opts)?
    let owner = common::param_str(params, "owner", "")
    let perms = common::param_strs(params, "permissions")
    let exact = mode_exact(params)?
    if owner == "" && perms.is_empty() && !exact { return Ok(ApplyResult::Success) }
    validate_perms(perms)?
    let aopts = acl_opts(params)?
    let want_owner = if owner != "" { access::sid_of(owner)? } else { "" }
    let cur = access::current("registry", hkey, aopts, true)?
    let rules = cur.explicit.clone()
    let drift: List[string] = []
    if !perms.is_empty() || exact {
        let wants = access::wanted("registry", perms, [], flags())?
        drift = access::drift(cur, wants, exact, false)
        if !drift.is_empty() { rules = access::merged(cur, wants, exact, false)? }
    }
    let new_owner = if want_owner != "" && cur.owner != want_owner { want_owner } else { "" }
    if drift.is_empty() && new_owner == "" { return Ok(ApplyResult::Success) }
    // acl::set always rewrites the explicit entries, and an object or
    // callback entry cannot be written back.
    if drift.is_empty() && cur.other > 0 {
        return Err("registry key " + key + " holds " + str(cur.other) + " object or callback entries, which changing the owner would drop")
    }
    log::info("setting the security of registry key " + key)
    acl::set(hkey, access::spec(rules, new_owner, None), aopts)?
    Ok(ApplyResult::Success)
}
