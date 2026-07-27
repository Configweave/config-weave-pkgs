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

// The params are lowercase symbols, matching this library's convention. The
// NetSecurity cmdlets speak PascalCase and `[string]$r.Direction` reports it
// that way, so each symbol is translated once here and that spelling is used
// for both the drift comparison and the cmdlet arguments.
fn ps_direction(params: Value) -> Result[string, string] {
    let d = param_str(params, "direction", "inbound")
    if d == "inbound" { return Ok("Inbound") }
    if d == "outbound" { return Ok("Outbound") }
    Err("invalid 'direction' value '" + d + "' (expected :inbound or :outbound)")
}

fn ps_action(params: Value) -> Result[string, string] {
    let a = param_str(params, "action", "allow")
    if a == "allow" { return Ok("Allow") }
    if a == "block" { return Ok("Block") }
    Err("invalid 'action' value '" + a + "' (expected :allow or :block)")
}

fn ps_protocol(params: Value) -> Result[string, string] {
    let p = param_str(params, "protocol", "tcp")
    if p == "tcp" { return Ok("TCP") }
    if p == "udp" { return Ok("UDP") }
    if p == "icmpv4" { return Ok("ICMPv4") }
    if p == "icmpv6" { return Ok("ICMPv6") }
    if p == "any" { return Ok("Any") }
    Err("invalid 'protocol' value '" + p + "' (expected :tcp, :udp, :icmpv4, :icmpv6 or :any)")
}

// -Profile takes a comma list, which is why the combinations are their own
// symbols rather than something the caller composes.
fn ps_profile(params: Value) -> Result[string, string] {
    let p = param_str(params, "profile", "any")
    if p == "any" { return Ok("Any") }
    if p == "domain" { return Ok("Domain") }
    if p == "private" { return Ok("Private") }
    if p == "public" { return Ok("Public") }
    if p == "domain_private" { return Ok("Domain,Private") }
    if p == "domain_public" { return Ok("Domain,Public") }
    if p == "private_public" { return Ok("Private,Public") }
    Err("invalid 'profile' value '" + p + "' (expected :any, :domain, :private, :public, :domain_private, :domain_public or :private_public)")
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
    if get_str(m, "direction") != ps_direction(params)? { return Ok(CheckResult::NotConfigured) }
    if get_str(m, "action") != ps_action(params)? { return Ok(CheckResult::NotConfigured) }
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
    let common = " -Direction " + ps_q(ps_direction(params)?) +
        " -Action " + ps_q(ps_action(params)?) +
        " -Protocol " + ps_q(ps_protocol(params)?) +
        " -Profile " + ps_q(ps_profile(params)?) +
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
