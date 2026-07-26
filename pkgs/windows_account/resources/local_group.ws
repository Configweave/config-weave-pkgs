use value
use shell
use json

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

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

// 'ABSENT' or a JSON object { description }.
fn probe(name: string) -> Result[string, string] {
    ps_out(
        "$g = Get-LocalGroup -Name " + ps_q(name) + " -ErrorAction SilentlyContinue; " +
        "if ($null -eq $g) {{ 'ABSENT' }} else {{ " +
        "[pscustomobject]@{{ description = \"$($g.Description)\" }} | ConvertTo-Json -Compress }}"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let st = probe(name)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let desc = param_str(params, "description", "")
    if desc != "" && get_str(json::parse(st)?, "description") != desc { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = ps_q(name)
    if !want_present(params)? {
        ps_run("if (Get-LocalGroup -Name " + qn + " -ErrorAction SilentlyContinue) {{ Remove-LocalGroup -Name " + qn + " }}")?
        return Ok(ApplyResult::Success)
    }
    let desc = param_str(params, "description", "")
    let desc_arg = if desc != "" { " -Description " + ps_q(desc) } else { "" }
    let update = if desc != "" { "Set-LocalGroup -Name " + qn + desc_arg } else { "" }
    ps_run(
        "if ($null -eq (Get-LocalGroup -Name " + qn + " -ErrorAction SilentlyContinue)) {{ " +
        "New-LocalGroup -Name " + qn + desc_arg + " | Out-Null }} " +
        "else {{ " + update + " }}"
    )?
    Ok(ApplyResult::Success)
}
