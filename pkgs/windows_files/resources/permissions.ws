use value
use fs
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
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

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

// One "identity:rights" spec -> [identity, rights]. rights is a
// System.Security.AccessControl.FileSystemRights name (FullControl,
// Modify, ReadAndExecute, ...). Identities must be written fully qualified
// (BUILTIN\Users, not Users) because the check compares the resolved names
// the ACL reports.
fn rule_parts(spec: string) -> Result[List[string], string] {
    if let Some(i) = spec.find(":") {
        let ident = spec.slice(0, i).trim()
        let rights = spec.slice(i + 1, spec.len()).trim()
        if ident != "" && rights != "" { return Ok([ident, rights]) }
    }
    Err("invalid acl entry '" + spec + "' (expected \"identity:rights\", e.g. \"BUILTIN\\Users:ReadAndExecute\")")
}

// The path's ACL as one JSON object:
// { owner, protected, rules: [{ id, rights, type }] }.
fn acl_ps(p: string) -> string {
    "$acl = Get-Acl -LiteralPath " + ps_q(p) + "; " +
    "[pscustomobject]@{{ " +
    "owner = \"$($acl.Owner)\"; " +
    "protected = [bool]$acl.AreAccessRulesProtected; " +
    "rules = @($acl.Access | ForEach-Object {{ [pscustomobject]@{{ " +
    "id = \"$($_.IdentityReference.Value)\"; " +
    "rights = [string]$_.FileSystemRights; " +
    "type = [string]$_.AccessControlType }} }}) " +
    "}} | ConvertTo-Json -Compress -Depth 4"
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
// satisfy a Modify spec, and generic-rights combinations that stringify
// numerically never match.
fn rule_grants(rule: Value, ident: string, right: string) -> bool {
    if get_str(rule, "type") != "Allow" { return false }
    if get_str(rule, "id").to_lower() != ident.to_lower() { return false }
    for tok in get_str(rule, "rights").split(",") {
        if tok.trim().to_lower() == right.to_lower() { return true }
    }
    false
}

fn any_rule_grants(rules: List[Value], ident: string, right: string) -> bool {
    for rule in rules {
        if rule_grants(rule, ident, right) { return true }
    }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    // A missing path is NotConfigured (not an error) so a sibling step can
    // create it before this resource's apply runs; apply still errors when
    // the path never appears.
    if !fs::exists(p) { return Ok(CheckResult::NotConfigured) }
    let acl = json::parse(ps_out(acl_ps(p))?)?
    let owner = param_str(params, "owner", "")
    if owner != "" && get_str(acl, "owner").to_lower() != owner.to_lower() {
        return Ok(CheckResult::NotConfigured)
    }
    if get_bool(acl, "protected") == param_bool(params, "inheritance", true) {
        return Ok(CheckResult::NotConfigured)
    }
    let rules = acl_rules(acl)
    for spec in param_list(params, "acl") {
        let parts = rule_parts(spec)?
        if !any_rule_grants(rules, parts.get(0).unwrap_or(""), parts.get(1).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    if !fs::exists(p) { return Err("path does not exist: " + p) }
    let parts = [
        "$path = " + ps_q(p) + "; " +
        "$item = Get-Item -LiteralPath $path -Force; " +
        "$acl = Get-Acl -LiteralPath $path; " +
        // Directories propagate their explicit rules to children; files
        // cannot carry inheritance flags at all.
        "$inh = 'None'; if ($item.PSIsContainer) {{ $inh = 'ContainerInherit,ObjectInherit' }}; "
    ]
    if param_bool(params, "inheritance", true) {
        parts.push("$acl.SetAccessRuleProtection($false, $false); ")
    } else {
        // Protect the ACL and drop the previously inherited rules.
        parts.push("$acl.SetAccessRuleProtection($true, $false); ")
    }
    let owner = param_str(params, "owner", "")
    if owner != "" {
        parts.push("$acl.SetOwner([System.Security.Principal.NTAccount]" + ps_q(owner) + "); ")
    }
    for spec in param_list(params, "acl") {
        let pp = rule_parts(spec)?
        parts.push(
            "$rule = New-Object System.Security.AccessControl.FileSystemAccessRule(" +
            ps_q(pp.get(0).unwrap_or("")) + ", " + ps_q(pp.get(1).unwrap_or("")) +
            ", $inh, 'None', 'Allow'); " +
            "$acl.AddAccessRule($rule); "
        )
    }
    parts.push("Set-Acl -LiteralPath $path -AclObject $acl")
    ps_run(parts.join(""))?
    Ok(ApplyResult::Success)
}
