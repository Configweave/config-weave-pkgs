use value
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

fn get_bool(m: Value, key: string) -> bool {
    if let Some(v) = m.get(key) { if let Some(b) = v.as_bool() { return b } }
    false
}

fn secure(pw: string) -> string {
    "(ConvertTo-SecureString " + ps_q(pw) + " -AsPlainText -Force)"
}

// 'ABSENT' or a JSON object { full_name, description, enabled }.
fn probe(name: string) -> Result[string, string] {
    ps_out(
        "$u = Get-LocalUser -Name " + ps_q(name) + " -ErrorAction SilentlyContinue; " +
        "if ($null -eq $u) {{ 'ABSENT' }} else {{ " +
        "[pscustomobject]@{{ full_name = \"$($u.FullName)\"; description = \"$($u.Description)\"; " +
        "enabled = [bool]$u.Enabled }} | ConvertTo-Json -Compress }}"
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
    // The password is never compared: Windows cannot read it back, so drift
    // is undetectable. force_password only changes what apply does when it
    // runs for some other reason (mirrors mssql.login).
    let u = json::parse(st)?
    let full = param_str(params, "full_name", "")
    if full != "" && get_str(u, "full_name") != full { return Ok(CheckResult::NotConfigured) }
    let desc = param_str(params, "description", "")
    if desc != "" && get_str(u, "description") != desc { return Ok(CheckResult::NotConfigured) }
    if get_bool(u, "enabled") == param_bool(params, "disabled", false) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = ps_q(name)
    if !want_present(params)? {
        ps_run("if (Get-LocalUser -Name " + qn + " -ErrorAction SilentlyContinue) {{ Remove-LocalUser -Name " + qn + " }}")?
        return Ok(ApplyResult::Success)
    }
    let pw = param_str(params, "password", "")
    let attrs = (if param_str(params, "full_name", "") != "" { " -FullName " + ps_q(param_str(params, "full_name", "")) } else { "" }) +
        (if param_str(params, "description", "") != "" { " -Description " + ps_q(param_str(params, "description", "")) } else { "" })
    let create = if pw == "" {
        "New-LocalUser -Name " + qn + " -NoPassword" + attrs + " | Out-Null"
    } else {
        "New-LocalUser -Name " + qn + " -Password " + secure(pw) + attrs + " | Out-Null"
    }
    let updates = (if attrs != "" { "Set-LocalUser -Name " + qn + attrs + "; " } else { "" }) +
        (if pw != "" && param_bool(params, "force_password", false) {
            "Set-LocalUser -Name " + qn + " -Password " + secure(pw) + "; "
        } else { "" })
    let state = if param_bool(params, "disabled", false) {
        "Disable-LocalUser -Name " + qn
    } else {
        "Enable-LocalUser -Name " + qn
    }
    ps_run(
        "if ($null -eq (Get-LocalUser -Name " + qn + " -ErrorAction SilentlyContinue)) {{ " + create + " }} " +
        "else {{ " + updates + " }}; " + state
    )?
    Ok(ApplyResult::Success)
}
