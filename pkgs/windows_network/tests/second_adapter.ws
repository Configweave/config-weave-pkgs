// Scenario driver for windows_network: static_ip and dns_servers on a second
// adapter whose segment hands out a DHCP lease (and, on the management
// adapter, DHCP-assigned DNS servers). Both resources used to read that
// DHCP state as their own converged static state. Last, static_ip's
// ensure = :absent hands the adapter back to DHCP.
//
// Symbol params are passed as plain strings: testlab renders a top-level
// string as a symbol when the param is declared `type = "symbol"`.

use testlab
use value

fn s(v: string) -> Value { Value::String(v) }

// check, apply, apply: the three-run protocol a `test` step gets.
fn converge(m: Machine, key: string, props: Value) -> Result[bool, string] {
    let c = m.check_resource(key, props)?
    if c.status != "not_configured" { return Err(key + ": expected not_configured on check, got " + c.status + " (" + c.message + ")") }
    let a = m.apply_resource(key, props)?
    if a.status != "configured" { return Err(key + ": expected configured on first apply, got " + a.status + " (" + a.message + ")") }
    let b = m.apply_resource(key, props)?
    if b.status != "already_configured" { return Err(key + ": expected already_configured on second apply, got " + b.status + " (" + b.message + ")") }
    Ok(true)
}

fn ps(m: Machine, script: string) -> Result[string, string] {
    let r = m.powershell("$ErrorActionPreference='Stop'; " + script)?
    if r.exit_code != 0 { return Err("powershell failed: " + r.stderr.trim()) }
    Ok(r.stdout.trim())
}

// A freshly booted guest's vmlab agent can drop the channel on its first
// execs while it settles (vmlab updates and restarts it), so the first
// contact is retried until a trivial command answers.
fn settle(m: Machine) -> Result[bool, string] {
    for i in 0..30 {
        if let Ok(r) = m.powershell("'ok'") {
            if r.stdout.trim() == "ok" { return Ok(true) }
        }
        if let Err(_) = m.wait_ready(60) { }
    }
    Err(m.name() + ": the guest agent never answered a command")
}

fn run(lab: Lab) -> Result[bool, string] {
    let m = lab.machine("net01")?
    settle(m)?

    // --- static_ip over a DHCP lease of the same address ------------------
    let lease = ps(m, "for ($i = 0; $i -lt 60; $i++) {{ $a = Get-NetIPAddress -InterfaceAlias 'Ethernet 2' -AddressFamily IPv4 -PrefixOrigin Dhcp -ErrorAction SilentlyContinue; if ($a) {{ break }}; Start-Sleep 2 }}; $a.IPAddress")?
    if lease == "" { return Err("Ethernet 2 never got a DHCP lease") }
    lab.log("Ethernet 2 holds the DHCP lease " + lease + "; making it static")
    converge(m, "windows_network.static_ip", Value::Map(#{
        "interface": s("Ethernet 2"),
        "ip": s(lease),
        "prefix_length": Value::Int(24)
    }))?
    let origin = ps(m, "$a = Get-NetIPAddress -InterfaceAlias 'Ethernet 2' -IPAddress '" + lease + "'; [string]$a.PrefixOrigin + '/' + [string](Get-NetIPInterface -InterfaceAlias 'Ethernet 2' -AddressFamily IPv4).Dhcp")?
    if origin != "Manual/Disabled" { return Err("Ethernet 2 address is " + origin + ", wanted Manual/Disabled") }

    // --- dns_servers: static servers on the second adapter ------------------
    converge(m, "windows_network.dns_servers", Value::Map(#{
        "interface": s("Ethernet 2"),
        "servers": Value::List([s("10.75.0.53"), s("fd00:75::53"), s("10.75.0.54")])
    }))?
    let guid = ps(m, "(Get-NetAdapter -Name 'Ethernet 2').InterfaceGuid")?
    // The registry strings carry trailing padding, so they are re-split.
    let ns_ps = "function NS($stack) {{ $v = [string](Get-ItemProperty ('HKLM:\\SYSTEM\\CurrentControlSet\\Services\\' + $stack + '\\Parameters\\Interfaces\\" + guid + "')).NameServer; " +
        "(@($v -split '[^0-9A-Fa-f:.]+') | Where-Object {{ $_ }}) -join ',' }}; (NS 'Tcpip') + '|' + (NS 'Tcpip6')"
    let ns = ps(m, ns_ps)?
    if ns != "10.75.0.53,10.75.0.54|fd00:75::53" { return Err("Ethernet 2 static DNS servers are '" + ns + "'") }

    // --- dns_servers: DHCP-assigned servers are not static ones -------------
    let dhcp_dns = ps(m, "@((Get-DnsClientServerAddress -InterfaceAlias 'Ethernet' -AddressFamily IPv4).ServerAddresses) -join ','")?
    if dhcp_dns == "" { return Err("Ethernet has no DHCP-assigned DNS server to test against") }
    lab.log("Ethernet has DHCP-assigned DNS " + dhcp_dns + "; pinning it as static")
    let pinned: List[Value] = []
    for a in dhcp_dns.split(",") { pinned.push(s(a)) }
    converge(m, "windows_network.dns_servers", Value::Map(#{
        "interface": s("Ethernet"),
        "servers": Value::List(pinned)
    }))?

    // An empty list removes the static servers again.
    converge(m, "windows_network.dns_servers", Value::Map(#{
        "interface": s("Ethernet 2"),
        "servers": Value::List([])
    }))?
    let left = ps(m, ns_ps)?
    if left != "|" { return Err("static DNS servers left on Ethernet 2: '" + left + "'") }

    // --- static_ip :absent: the address goes and DHCP comes back -------------
    lab.log("removing the static " + lease + " from Ethernet 2")
    converge(m, "windows_network.static_ip", Value::Map(#{
        "interface": s("Ethernet 2"),
        "ip": s(lease),
        "prefix_length": Value::Int(24),
        "ensure": s("absent")
    }))?
    let back = ps(m, "$d = [string](Get-NetIPInterface -InterfaceAlias 'Ethernet 2' -AddressFamily IPv4).Dhcp; " +
        "$man = @(Get-NetIPAddress -InterfaceAlias 'Ethernet 2' -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue).Count; " +
        "$d + '/' + $man")?
    if back != "Enabled/0" { return Err("Ethernet 2 after static_ip :absent is DHCP/manual-count " + back + ", wanted Enabled/0") }
    Ok(true)
}
