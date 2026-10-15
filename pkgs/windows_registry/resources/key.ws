use value
use log
use registry
use common
use acl

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
    let prelude = if managed { acl::ps_prelude(owner, perms, exact)? } else { "" }
    let exists = registry::key_exists_with(common::host_key(hive, sub), opts)?
    if !present {
        if exists { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !exists { return Ok(CheckResult::NotConfigured) }
    if !managed { return Ok(CheckResult::AlreadyConfigured) }
    let st = common::ps_json("reading the security of registry key " + key,
        common::ps_open(hive, view, sub) + prelude +
        "$k = $base.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadSubTree, [System.Security.AccessControl.RegistryRights]::ReadKey)\n" +
        "$acl = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]'Owner, Access')\n" +
        "$drift = CwEval $acl\n" +
        "$have = $acl.GetOwner([System.Security.Principal.SecurityIdentifier]).Value\n" +
        "if ($cwOwner -ne '' -and $have -ne $cwOwner) {{ $drift.Add('owner is ' + $have + ', wanted ' + $cwOwner) }}\n" +
        "[pscustomobject]@{{ drift = @($drift) }} | ConvertTo-Json -Compress\n"
    )?
    let drift = common::get_list(st, "drift")
    if !drift.is_empty() {
        for d in drift { log::info(key + ": " + d.as_string().unwrap_or("")) }
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
    let script = common::ps_open(hive, view, sub) + acl::ps_prelude(owner, perms, exact)? +
        "$k = $base.OpenSubKey($sub, [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree, [System.Security.AccessControl.RegistryRights]'ReadKey, WriteKey, ChangePermissions, TakeOwnership')\n" +
        // The owner and the DACL are written separately, each with only its
        // own section loaded, so neither write touches the other.
        "if ($cwOwner -ne '') {{\n" +
        "  $o = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)\n" +
        "  if ($o.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $cwOwner) {{\n" +
        "    CwEnableOwnerPrivileges\n" +
        "    $o.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($cwOwner)))\n" +
        "    $k.SetAccessControl($o)\n" +
        "  }}\n" +
        "}}\n" +
        "if ($cwWant.Count -gt 0 -or $cwExact) {{\n" +
        "  $a = $k.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)\n" +
        "  $drift = CwEval $a\n" +
        "  if ($drift.Count -gt 0) {{\n" +
        "    if ($cwExact) {{ foreach ($r in (CwExplicit $a)) {{ $null = $a.RemoveAccessRuleSpecific($r) }} }}\n" +
        "    foreach ($w in $cwWant.Values) {{\n" +
        "      if ($cwExact -or -not $w.ok) {{ $a.AddAccessRule((CwRule $w.sid $w.mask $w.type)) }}\n" +
        "    }}\n" +
        "    $k.SetAccessControl($a)\n" +
        "  }}\n" +
        "}}\n"
    common::ps_run("setting the security of registry key " + key, script)?
    Ok(ApplyResult::Success)
}
