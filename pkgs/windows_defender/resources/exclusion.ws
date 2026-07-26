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

// kind -> the MpPreference property / Set flag name (they coincide).
fn flag(params: Value) -> Result[string, string] {
    let kind = param_str(params, "kind", "")
    if kind == "path" { return Ok("ExclusionPath") }
    if kind == "extension" { return Ok("ExclusionExtension") }
    if kind == "process" { return Ok("ExclusionProcess") }
    Err("invalid 'kind' value '" + kind + "' (expected path, extension or process)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let prop = flag(params)?
    let value = param_str(params, "value", "")
    if value == "" { return Err("missing 'value' parameter") }
    // -contains compares case-insensitively, matching Defender's semantics.
    let st = ps_out(
        "$v = @((Get-MpPreference)." + prop + "); " +
        "if ($v -contains " + ps_q(value) + ") {{ 'PRESENT' }} else {{ 'ABSENT' }}"
    )?
    if want_present(params)? {
        if st == "PRESENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "PRESENT" { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let prop = flag(params)?
    let value = param_str(params, "value", "")
    if value == "" { return Err("missing 'value' parameter") }
    let cmdlet = if want_present(params)? { "Add-MpPreference" } else { "Remove-MpPreference" }
    ps_run(cmdlet + " -" + prop + " " + ps_q(value))?
    Ok(ApplyResult::Success)
}
