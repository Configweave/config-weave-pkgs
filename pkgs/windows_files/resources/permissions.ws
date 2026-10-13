use value
use fs
use log
use common
use acl

fn mode_exact(params: Value) -> Result[bool, string] {
    let m = common::param_str(params, "acl_mode", "additive")
    if m == "additive" { return Ok(false) }
    if m == "exact" { return Ok(true) }
    Err("invalid 'acl_mode' value '" + m + "' (expected :additive or :exact)")
}

fn copy_inherited(params: Value) -> Result[bool, string] {
    let m = common::param_str(params, "inherited_rules", "copy")
    if m == "copy" { return Ok(true) }
    if m == "remove" { return Ok(false) }
    Err("invalid 'inherited_rules' value '" + m + "' (expected :copy or :remove)")
}

fn prelude(params: Value, p: string) -> Result[string, string] {
    copy_inherited(params)?
    acl::ps_prelude(
        p,
        common::param_str(params, "owner", ""),
        common::param_strs(params, "acl"),
        common::param_strs(params, "deny"),
        mode_exact(params)?
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let script = prelude(params, p)?
    // A missing path is NotConfigured (not an error) so a sibling step can
    // create it before this resource's apply runs; apply still errors when
    // the path never appears.
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    let inheritance = common::param_bool(params, "inheritance", true)
    let st = common::ps_json("reading the ACL of " + p,
        script +
        "$sec = $cwItem.GetAccessControl([System.Security.AccessControl.AccessControlSections]'Owner, Access')\n" +
        "$drift = CwEval $sec\n" +
        "$have = $sec.GetOwner([System.Security.Principal.SecurityIdentifier]).Value\n" +
        "if ($cwOwner -ne '' -and $have -ne $cwOwner) {{ $drift.Add('owner is ' + $have + ', wanted ' + $cwOwner) }}\n" +
        "if ($sec.AreAccessRulesProtected -eq $" + (if inheritance { "true" } else { "false" }) + ") {{ $drift.Add('inheritance is ' + $(if ($sec.AreAccessRulesProtected) {{ 'off' }} else {{ 'on' }})) }}\n" +
        "[pscustomobject]@{{ drift = @($drift) }} | ConvertTo-Json -Compress\n"
    )?
    let drift = common::get_list(st, "drift")
    if !drift.is_empty() {
        for d in drift { log::info(p + ": " + d.as_string().unwrap_or("")) }
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let script = prelude(params, p)?
    if !fs::exists(p) { return Err("path does not exist: " + p) }
    let inheritance = common::param_bool(params, "inheritance", true)
    let copy = copy_inherited(params)?
    log::info("setting the ACL of " + p)
    // The owner and the DACL are read and written separately through the
    // item's own GetAccessControl/SetAccessControl, each with only its own
    // section loaded. Set-Acl would write the owner back with the DACL,
    // which fails on paths owned by TrustedInstaller and similar.
    common::ps_run("setting the ACL of " + p,
        script +
        "if ($cwOwner -ne '') {{\n" +
        "  $o = $cwItem.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Owner)\n" +
        "  if ($o.GetOwner([System.Security.Principal.SecurityIdentifier]).Value -ne $cwOwner) {{\n" +
        "    CwEnableOwnerPrivileges\n" +
        "    $o.SetOwner((New-Object System.Security.Principal.SecurityIdentifier($cwOwner)))\n" +
        "    $cwItem.SetAccessControl($o)\n" +
        "  }}\n" +
        "}}\n" +
        "$a = $cwItem.GetAccessControl([System.Security.AccessControl.AccessControlSections]::Access)\n" +
        "$changed = $false\n" +
        (if inheritance {
            "if ($a.AreAccessRulesProtected) {{ $a.SetAccessRuleProtection($false, $false); $changed = $true }}\n"
        } else {
            // Copying turns the inherited rules into explicit ones before
            // inheritance is cut, so nobody loses access they had.
            "if (-not $a.AreAccessRulesProtected) {{ $a.SetAccessRuleProtection($true, $" + (if copy { "true" } else { "false" }) + "); $changed = $true }}\n"
        }) +
        "$drift = CwEval $a\n" +
        "if ($drift.Count -gt 0) {{\n" +
        "  if ($cwExact) {{ foreach ($r in (CwExplicit $a)) {{ $null = $a.RemoveAccessRuleSpecific($r) }} }}\n" +
        "  foreach ($w in $cwWant.Values) {{\n" +
        "    if ($cwExact -or -not $w.ok) {{ $a.AddAccessRule((CwRule $w.sid $w.mask $w.type)) }}\n" +
        "  }}\n" +
        "  $changed = $true\n" +
        "}}\n" +
        "if ($changed) {{ $cwItem.SetAccessControl($a) }}\n"
    )?
    Ok(ApplyResult::Success)
}
