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

// 'ABSENT' or a JSON object { enabled, direction, action, profile, protocol,
// local_port, remote_address }. The port and address filters are separate CIM
// objects, read in the same PowerShell call so check stays one round trip;
// their multi-valued fields come back comma-joined.
fn probe(name: string) -> Result[string, string] {
    ps_out(
        "$r = Get-NetFirewallRule -Name " + ps_q(name) + " -ErrorAction SilentlyContinue; " +
        "if ($null -eq $r) {{ 'ABSENT' }} else {{ " +
        "$pf = $r | Get-NetFirewallPortFilter; $af = $r | Get-NetFirewallAddressFilter; " +
        "[pscustomobject]@{{ enabled = ([string]$r.Enabled -eq 'True'); " +
        "direction = [string]$r.Direction; action = [string]$r.Action; profile = [string]$r.Profile; " +
        "protocol = [string]$pf.Protocol; local_port = (@($pf.LocalPort) -join ','); " +
        "remote_address = (@($af.RemoteAddress) -join ',') }} | ConvertTo-Json -Compress }}"
    )
}

// Ports only exist for TCP and UDP: the cmdlets reject -LocalPort for any
// other protocol, so apply only writes it, and check only compares it, here.
fn has_ports(protocol: string) -> bool { protocol == "TCP" || protocol == "UDP" }

// Empty means any, and apply writes it as `Any` so a narrowed filter is
// widened back rather than left in place.
fn want_local_port(params: Value) -> string {
    let p = param_str(params, "local_port", "")
    if p == "" { "Any" } else { p }
}

fn want_remote_address(params: Value) -> string {
    let a = param_str(params, "remote_address", "")
    if a == "" { "Any" } else { a }
}

// a.b.c.d/n as the dotted mask Windows reports it with (a.b.c.d/m.m.m.m), or
// the address unchanged when it is not IPv4 CIDR.
fn ipv4_cidr_to_mask(addr: string) -> string {
    let parts = addr.split("/")
    if parts.len() != 2 || parts[0].contains(":") { return addr }
    if let Some(n) = parts[1].parse_int() {
        if n < 0 || n > 32 { return addr }
        let octet = ["0", "128", "192", "224", "240", "248", "252", "254", "255"]
        let octets: List[string] = []
        let left = n
        for _i in 0..4 {
            let bits = if left >= 8 { 8 } else { left }
            octets.push(octet[bits])
            left = left - bits
        }
        return parts[0] + "/" + octets.join(".")
    }
    addr
}

// A comma list as an order-insensitive, case-insensitive, whitespace-free set,
// so the param's spelling and Windows' read-back compare equal. The PowerShell
// enum flags (`Domain, Private`) and address lists both pass through here.
fn norm_list(s: string, cidr: bool) -> string {
    let items: List[string] = []
    for p in s.split(",") {
        let t = p.trim().to_lower()
        if t != "" { items.push(if cidr { ipv4_cidr_to_mask(t) } else { t }) }
    }
    items.sort()
    items.join(",")
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
    // Every field apply writes is compared, spelled the way apply writes it.
    let m = json::parse(st)?
    if get_bool(m, "enabled") != param_bool(params, "enabled", true) { return Ok(CheckResult::NotConfigured) }
    if get_str(m, "direction") != ps_direction(params)? { return Ok(CheckResult::NotConfigured) }
    if get_str(m, "action") != ps_action(params)? { return Ok(CheckResult::NotConfigured) }
    if norm_list(get_str(m, "profile"), false) != norm_list(ps_profile(params)?, false) { return Ok(CheckResult::NotConfigured) }
    let protocol = ps_protocol(params)?
    if get_str(m, "protocol").to_lower() != protocol.to_lower() { return Ok(CheckResult::NotConfigured) }
    if has_ports(protocol) && norm_list(get_str(m, "local_port"), false) != norm_list(want_local_port(params), false) {
        return Ok(CheckResult::NotConfigured)
    }
    if norm_list(get_str(m, "remote_address"), true) != norm_list(want_remote_address(params), true) {
        return Ok(CheckResult::NotConfigured)
    }
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
    let protocol = ps_protocol(params)?
    let common = " -Direction " + ps_q(ps_direction(params)?) +
        " -Action " + ps_q(ps_action(params)?) +
        " -Protocol " + ps_q(protocol) +
        " -Profile " + ps_q(ps_profile(params)?) +
        " -Enabled " + (if param_bool(params, "enabled", true) { "True" } else { "False" }) +
        (if has_ports(protocol) { " -LocalPort " + ps_q(want_local_port(params)) } else { "" }) +
        " -RemoteAddress " + ps_q(want_remote_address(params))
    ps_run(
        "if ($null -eq (Get-NetFirewallRule -Name " + qn + " -ErrorAction SilentlyContinue)) {{ " +
        "New-NetFirewallRule -Name " + qn + " -DisplayName " + qn + common + " | Out-Null }} " +
        "else {{ Set-NetFirewallRule -Name " + qn + common + " }}"
    )?
    Ok(ApplyResult::Success)
}
