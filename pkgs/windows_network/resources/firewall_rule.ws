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

// 'ABSENT' or a JSON object { enabled, direction, action }.
fn probe(name: string) -> Result[string, string] {
    ps_out(
        "$r = Get-NetFirewallRule -Name " + ps_q(name) + " -ErrorAction SilentlyContinue; " +
        "if ($null -eq $r) {{ 'ABSENT' }} else {{ " +
        "[pscustomobject]@{{ enabled = ([string]$r.Enabled -eq 'True'); " +
        "direction = [string]$r.Direction; action = [string]$r.Action }} | ConvertTo-Json -Compress }}"
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
    // Pragmatic drift detection: existence + enabled + direction + action.
    // Port/address/profile filters are pushed on every apply but reading them
    // back (Get-NetFirewallPortFilter et al.) is skipped to keep the probe
    // cheap and the comparison unambiguous.
    let m = json::parse(st)?
    if get_bool(m, "enabled") != param_bool(params, "enabled", true) { return Ok(CheckResult::NotConfigured) }
    if get_str(m, "direction") != param_str(params, "direction", "Inbound") { return Ok(CheckResult::NotConfigured) }
    if get_str(m, "action") != param_str(params, "action", "Allow") { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = ps_q(name)
    if !want_present(params)? {
        ps_run(
            "if (Get-NetFirewallRule -Name " + qn + " -ErrorAction SilentlyContinue) {{ " +
            "Remove-NetFirewallRule -Name " + qn + " }}"
        )?
        return Ok(ApplyResult::Success)
    }
    let local_port = param_str(params, "local_port", "")
    let remote = param_str(params, "remote_address", "")
    let common = " -Direction " + ps_q(param_str(params, "direction", "Inbound")) +
        " -Action " + ps_q(param_str(params, "action", "Allow")) +
        " -Protocol " + ps_q(param_str(params, "protocol", "TCP")) +
        " -Profile " + ps_q(param_str(params, "profile", "Any")) +
        " -Enabled " + (if param_bool(params, "enabled", true) { "True" } else { "False" }) +
        (if local_port != "" { " -LocalPort " + ps_q(local_port) } else { "" }) +
        (if remote != "" { " -RemoteAddress " + ps_q(remote) } else { "" })
    ps_run(
        "if ($null -eq (Get-NetFirewallRule -Name " + qn + " -ErrorAction SilentlyContinue)) {{ " +
        "New-NetFirewallRule -Name " + qn + " -DisplayName " + qn + common + " | Out-Null }} " +
        "else {{ Set-NetFirewallRule -Name " + qn + common + " }}"
    )?
    Ok(ApplyResult::Success)
}
