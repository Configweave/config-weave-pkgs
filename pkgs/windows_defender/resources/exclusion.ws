use value
use common

// kind -> the MpPreference property / Add-/Remove-MpPreference flag name
// (they coincide).
fn flag(params: Value) -> Result[string, string] {
    let kind = common::param_str(params, "kind", "")
    if kind == "path" { return Ok("ExclusionPath") }
    if kind == "extension" { return Ok("ExclusionExtension") }
    if kind == "process" { return Ok("ExclusionProcess") }
    if kind == "ip_address" { return Ok("ExclusionIpAddress") }
    Err("invalid 'kind' value '" + kind + "' (expected :path, :extension, :process or :ip_address)")
}

fn value_of(params: Value) -> Result[string, string] {
    let value = common::param_str(params, "value", "")
    if value == "" { return Err("missing 'value' parameter") }
    common::single_line("value", value)?
    Ok(value)
}

// 'PRESENT' or 'ABSENT'. When HideExclusionsFromLocalAdmins is on, a caller
// that may not see the list gets one "N/A: ..." entry instead of it; that is
// an error, not an empty list.
fn probe(prop: string, value: string) -> Result[string, string] {
    common::ps("reading Defender " + prop,
        "$v = @((Get-MpPreference)." + prop + "); " +
        "if (@($v | Where-Object {{ \"$_\" -like 'N/A*' }}).Count -gt 0) {{ throw ('Defender hides its exclusions from this account: ' + ($v -join ' ')) }}; " +
        // -contains compares case-insensitively, matching Defender's semantics.
        "if ($v -contains " + common::ps_q(value) + ") {{ 'PRESENT' }} else {{ 'ABSENT' }}")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let prop = flag(params)?
    let value = value_of(params)?
    let st = probe(prop, value)?
    if common::want_present(params)? {
        if st == "PRESENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "PRESENT" { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let prop = flag(params)?
    let value = value_of(params)?
    let cmdlet = if common::want_present(params)? { "Add-MpPreference" } else { "Remove-MpPreference" }
    common::ps(cmdlet + " -" + prop, cmdlet + " -" + prop + " " + common::ps_q(value))?
    Ok(ApplyResult::Success)
}
