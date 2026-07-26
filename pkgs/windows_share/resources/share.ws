use value
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
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

// The share's access entries as a list whether JSON carried a list or a
// single collapsed object (ConvertTo-Json in Windows PowerShell 5.1).
fn access_entries(share: Value) -> List[Value] {
    let entries = []
    if let Some(v) = share.get("access") {
        if let Some(items) = v.as_list() {
            for item in items { entries.push(item) }
        } else if let Some(single) = v.as_map() {
            entries.push(Value::Map(single))
        }
    }
    entries
}

// 'ABSENT' or a JSON object { path, description, access: [{ name, right, type }] }.
fn probe(name: string) -> Result[string, string] {
    let qn = ps_q(name)
    ps_out(
        "$s = Get-SmbShare -Name " + qn + " -ErrorAction SilentlyContinue; " +
        "if ($null -eq $s) {{ 'ABSENT' }} else {{ " +
        "[pscustomobject]@{{ path = $s.Path; description = \"$($s.Description)\"; " +
        "access = @(Get-SmbShareAccess -Name " + qn + " | ForEach-Object {{ " +
        "[pscustomobject]@{{ name = \"$($_.AccountName)\"; right = [string]$_.AccessRight; type = [string]$_.AccessControlType }} " +
        "}}) }} | ConvertTo-Json -Compress -Depth 4 }}"
    )
}

// Accounts come back qualified (BUILTIN\Administrators, DOMAIN\user), so a
// spec matches on the exact name or on the part after the backslash.
fn has_access(entries: List[Value], account: string, right: string) -> bool {
    let want = account.to_lower()
    for e in entries {
        if get_str(e, "type") != "Allow" { continue }
        if get_str(e, "right") != right { continue }
        let acct = get_str(e, "name").to_lower()
        if acct == want || acct.ends_with("\\" + want) { return true }
    }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let st = probe(name)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let path = param_str(params, "path", "")
    if path == "" { return Err("'path' is required when ensure is :present") }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let s = json::parse(st)?
    if get_str(s, "path").to_lower() != path.to_lower() { return Ok(CheckResult::NotConfigured) }
    let desc = param_str(params, "description", "")
    if desc != "" && get_str(s, "description") != desc { return Ok(CheckResult::NotConfigured) }
    // Each declared grant must be present; extra grants (e.g. the default
    // Everyone read entry) are tolerated rather than revoked.
    let entries = access_entries(s)
    for account in param_list(params, "full_access") {
        if !has_access(entries, account, "Full") { return Ok(CheckResult::NotConfigured) }
    }
    for account in param_list(params, "change_access") {
        if !has_access(entries, account, "Change") { return Ok(CheckResult::NotConfigured) }
    }
    for account in param_list(params, "read_access") {
        if !has_access(entries, account, "Read") { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn access_arg(flag: string, accounts: List[string]) -> string {
    if accounts.is_empty() { return "" }
    " -" + flag + " " + accounts.map(|a| ps_q(a)).join(",")
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = ps_q(name)
    if !want_present(params)? {
        ps_run("if (Get-SmbShare -Name " + qn + " -ErrorAction SilentlyContinue) {{ Remove-SmbShare -Name " + qn + " -Force }}")?
        return Ok(ApplyResult::Success)
    }
    let path = param_str(params, "path", "")
    if path == "" { return Err("'path' is required when ensure is :present") }
    let desc = param_str(params, "description", "")
    // Drop-and-recreate rather than reconciling with Grant-/Revoke-
    // SmbShareAccess: New-SmbShare applies the declared grants atomically and
    // there is no partial-ACL state to reason about. The cost is that open
    // SMB sessions to a drifted share are cut for a moment.
    ps_run(
        "if (Get-SmbShare -Name " + qn + " -ErrorAction SilentlyContinue) {{ Remove-SmbShare -Name " + qn + " -Force }}; " +
        "if (-not (Test-Path -LiteralPath " + ps_q(path) + ")) {{ " +
        "New-Item -ItemType Directory -Path " + ps_q(path) + " | Out-Null }}; " +
        "New-SmbShare -Name " + qn + " -Path " + ps_q(path) +
        (if desc != "" { " -Description " + ps_q(desc) } else { "" }) +
        access_arg("FullAccess", param_list(params, "full_access")) +
        access_arg("ChangeAccess", param_list(params, "change_access")) +
        access_arg("ReadAccess", param_list(params, "read_access")) +
        " | Out-Null"
    )?
    Ok(ApplyResult::Success)
}
