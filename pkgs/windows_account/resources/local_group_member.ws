use value
use shell

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
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

// Member names come back qualified (COMPUTER\name or DOMAIN\name), so a spec
// matches on the exact name or on the part after the backslash.
fn member_filter(member: string) -> string {
    let qm = ps_q(member)
    "Where-Object {{ $_.Name -eq " + qm + " -or $_.Name.ToLower().EndsWith(('\\' + " + qm + ").ToLower()) }}"
}

fn probe(group: string, member: string) -> Result[string, string] {
    ps_out(
        "$hits = @(Get-LocalGroupMember -Group " + ps_q(group) + " -ErrorAction SilentlyContinue | " +
        member_filter(member) + "); " +
        "if ($hits.Count -gt 0) {{ 'PRESENT' }} else {{ 'ABSENT' }}"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let group = param_str(params, "group", "")
    if group == "" { return Err("missing 'group' parameter") }
    let member = param_str(params, "member", "")
    if member == "" { return Err("missing 'member' parameter") }
    let st = probe(group, member)?
    if want_present(params)? {
        if st == "PRESENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "PRESENT" { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let group = param_str(params, "group", "")
    if group == "" { return Err("missing 'group' parameter") }
    let member = param_str(params, "member", "")
    if member == "" { return Err("missing 'member' parameter") }
    let qg = ps_q(group)
    if want_present(params)? {
        ps_run("Add-LocalGroupMember -Group " + qg + " -Member " + ps_q(member))?
        return Ok(ApplyResult::Success)
    }
    // Remove by the qualified name reported by Get-LocalGroupMember so a bare
    // member spec still removes COMPUTER\member.
    ps_run(
        "$hits = @(Get-LocalGroupMember -Group " + qg + " -ErrorAction SilentlyContinue | " +
        member_filter(member) + "); " +
        "foreach ($m in $hits) {{ Remove-LocalGroupMember -Group " + qg + " -Member $m.Name }}"
    )?
    Ok(ApplyResult::Success)
}
