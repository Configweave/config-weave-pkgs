use value
use common

// The params are lowercase symbols, matching this library's convention. The
// NetSecurity cmdlets speak PascalCase and `[string]$r.Direction` reports it
// that way, so each symbol is translated once here and that spelling is used
// for both the drift comparison and the cmdlet arguments.
fn ps_direction(params: Value) -> Result[string, string] {
    let d = common::param_str(params, "direction", "inbound")
    if d == "inbound" { return Ok("Inbound") }
    if d == "outbound" { return Ok("Outbound") }
    Err("invalid 'direction' value '" + d + "' (expected :inbound or :outbound)")
}

fn ps_action(params: Value) -> Result[string, string] {
    let a = common::param_str(params, "action", "allow")
    if a == "allow" { return Ok("Allow") }
    if a == "block" { return Ok("Block") }
    Err("invalid 'action' value '" + a + "' (expected :allow or :block)")
}

fn ps_protocol(params: Value) -> Result[string, string] {
    let p = common::param_str(params, "protocol", "tcp")
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
    let p = common::param_str(params, "profile", "any")
    if p == "any" { return Ok("Any") }
    if p == "domain" { return Ok("Domain") }
    if p == "private" { return Ok("Private") }
    if p == "public" { return Ok("Public") }
    if p == "domain_private" { return Ok("Domain,Private") }
    if p == "domain_public" { return Ok("Domain,Public") }
    if p == "private_public" { return Ok("Private,Public") }
    Err("invalid 'profile' value '" + p + "' (expected :any, :domain, :private, :public, :domain_private, :domain_public or :private_public)")
}

// Get-NetFirewallRule -Name expands *?[], so 'web*' would select, and
// :absent delete, every rule starting with 'web'.
fn rule_name(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::no_wildcards("name", name)?
    common::single_line("local_port", common::param_str(params, "local_port", ""))?
    common::single_line("remote_address", common::param_str(params, "remote_address", ""))?
    Ok(name)
}

// 'ABSENT' or a JSON object { enabled, direction, action, profile, protocol,
// local_port, remote_address }. The port and address filters are separate CIM
// objects, read in the same PowerShell call so check stays one round trip;
// their multi-valued fields come back comma-joined.
fn probe(name: string) -> Result[string, string] {
    common::ps("reading firewall rule '" + name + "'",
        "$r = $null; try {{ $r = Get-NetFirewallRule -Name " + common::ps_q(name) + " }} " +
        "catch {{ if ($_.CategoryInfo.Category -ne 'ObjectNotFound') {{ throw }} }}; " +
        "if ($null -eq $r) {{ 'ABSENT' }} else {{ " +
        "$pf = $r | Get-NetFirewallPortFilter; $af = $r | Get-NetFirewallAddressFilter; " +
        "[pscustomobject]@{{ enabled = ([string]$r.Enabled -eq 'True'); " +
        "direction = [string]$r.Direction; action = [string]$r.Action; profile = [string]$r.Profile; " +
        "protocol = [string]$pf.Protocol; local_port = (@($pf.LocalPort) -join ','); " +
        "remote_address = (@($af.RemoteAddress) -join ',') }} | ConvertTo-Json -Compress }}")
}

// Ports only exist for TCP and UDP: the cmdlets reject a port list for any
// other protocol, so apply only writes one, and check only compares it, here.
fn has_ports(protocol: string) -> bool { protocol == "TCP" || protocol == "UDP" }

// Empty means any, and apply writes it as `Any` so a narrowed filter is
// widened back rather than left in place.
fn want_local_port(params: Value) -> string {
    let p = common::param_str(params, "local_port", "")
    if p == "" { "Any" } else { p }
}

fn want_remote_address(params: Value) -> string {
    let a = common::param_str(params, "remote_address", "")
    if a == "" { "Any" } else { a }
}

// A comma list as a PowerShell array, so "80, 443" reaches the cmdlet as two
// entries rather than one invalid one.
fn ps_items(s: string) -> string {
    let items: List[string] = []
    for p in s.split(",") {
        let t = p.trim()
        if t != "" { items.push(t) }
    }
    common::ps_list(items)
}

fn mask_octet(bits: int) -> int {
    let octet = [0, 128, 192, 224, 240, 248, 252, 254, 255]
    octet[bits]
}

fn prefix_of_mask(mask: List[int]) -> Option[int] {
    let n = 0
    let ended = false
    for o in mask {
        let found = false
        for bits in 0..9 {
            if mask_octet(bits) == o {
                if ended && bits != 0 { return None }
                n = n + bits
                if bits != 8 { ended = true }
                found = true
                break
            }
        }
        if !found { return None }
    }
    Some(n)
}

// An address entry the way Windows stores it: IPv4 a.b.c.d/n (or a dotted
// mask) becomes network/m.m.m.m with the host bits cleared, and a
// single-host /32 (IPv6 /128) becomes the bare address. Ranges and keywords
// (LocalSubnet, 10.0.0.1-10.0.0.5) pass through.
fn canonical_address(addr: string) -> string {
    let parts = addr.split("/")
    if parts.len() != 2 { return addr }
    if parts[0].contains(":") {
        if parts[1] == "128" { return parts[0] }
        return addr
    }
    if let Some(ip) = common::octets(parts[0]) {
        let n = if let Some(m) = common::octets(parts[1]) { prefix_of_mask(m) } else { parts[1].parse_int() }
        if let Some(n) = n {
            if n < 0 || n > 32 { return addr }
            if n == 32 { return parts[0] }
            let net: List[string] = []
            let mask: List[string] = []
            let left = n
            for i in 0..4 {
                let bits = if left >= 8 { 8 } else { left }
                let m = mask_octet(bits)
                // Bitwise AND of an octet with a contiguous mask octet.
                let keep = ip[i] - (ip[i] % (256 - m))
                net.push(str(if m == 0 { 0 } else { keep }))
                mask.push(str(m))
                left = left - bits
            }
            return net.join(".") + "/" + mask.join(".")
        }
    }
    addr
}

// A comma list as an order-insensitive, case-insensitive, whitespace-free set,
// so the param's spelling and Windows' read-back compare equal. The PowerShell
// enum flags (`Domain, Private`) and address lists both pass through here.
fn norm_list(s: string, addresses: bool) -> string {
    let items: List[string] = []
    for p in s.split(",") {
        let t = p.trim().to_lower()
        if t != "" { items.push(if addresses { canonical_address(t) } else { t }) }
    }
    items.sort()
    items.join(",")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = rule_name(params)?
    let st = probe(name)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    // Every field apply writes is compared, spelled the way apply writes it.
    let m = common::parse(st)?
    if common::get_bool(m, "enabled") != common::param_bool(params, "enabled", true) { return Ok(CheckResult::NotConfigured) }
    if common::get_str(m, "direction") != ps_direction(params)? { return Ok(CheckResult::NotConfigured) }
    if common::get_str(m, "action") != ps_action(params)? { return Ok(CheckResult::NotConfigured) }
    if norm_list(common::get_str(m, "profile"), false) != norm_list(ps_profile(params)?, false) { return Ok(CheckResult::NotConfigured) }
    let protocol = ps_protocol(params)?
    if common::get_str(m, "protocol").to_lower() != protocol.to_lower() { return Ok(CheckResult::NotConfigured) }
    if has_ports(protocol) && norm_list(common::get_str(m, "local_port"), false) != norm_list(want_local_port(params), false) {
        return Ok(CheckResult::NotConfigured)
    }
    if norm_list(common::get_str(m, "remote_address"), true) != norm_list(want_remote_address(params), true) {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = rule_name(params)?
    let qn = common::ps_q(name)
    let fetch = "$r = $null; try {{ $r = Get-NetFirewallRule -Name " + qn + " }} " +
        "catch {{ if ($_.CategoryInfo.Category -ne 'ObjectNotFound') {{ throw }} }}; "
    if !common::want_present(params)? {
        common::ps("removing firewall rule '" + name + "'", fetch + "if ($r) {{ Remove-NetFirewallRule -Name " + qn + " }}")?
        return Ok(ApplyResult::Success)
    }
    let protocol = ps_protocol(params)?
    // A protocol without ports still gets -LocalPort Any, so a rule moving
    // from TCP or UDP to ICMP or Any drops the port list it had.
    let port = if has_ports(protocol) { ps_items(want_local_port(params)) } else { "'Any'" }
    let shared = " -Direction " + common::ps_q(ps_direction(params)?) +
        " -Action " + common::ps_q(ps_action(params)?) +
        " -Protocol " + common::ps_q(protocol) +
        " -LocalPort " + port +
        " -Profile " + common::ps_q(ps_profile(params)?) +
        " -Enabled " + (if common::param_bool(params, "enabled", true) { "True" } else { "False" }) +
        " -RemoteAddress " + ps_items(want_remote_address(params))
    common::ps("configuring firewall rule '" + name + "'",
        fetch +
        "if ($null -eq $r) {{ New-NetFirewallRule -Name " + qn + " -DisplayName " + qn + shared + " | Out-Null }} " +
        "else {{ Set-NetFirewallRule -Name " + qn + shared + " }}")?
    Ok(ApplyResult::Success)
}
