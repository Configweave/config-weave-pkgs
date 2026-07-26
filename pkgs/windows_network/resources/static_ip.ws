use value
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(n) = v.as_int() { return n } }
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

fn get_int(m: Value, key: string) -> int {
    if let Some(v) = m.get(key) { if let Some(n) = v.as_int() { return n } }
    0
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

// 'ABSENT' or a JSON object { prefix, gateway } — gateway is the interface's
// current IPv4 default-route next hop ('' when it has none).
fn probe(iface: string, ip: string) -> Result[string, string] {
    let qi = ps_q(iface)
    ps_out(
        "$a = Get-NetIPAddress -InterfaceAlias " + qi + " -IPAddress " + ps_q(ip) +
        " -AddressFamily IPv4 -ErrorAction SilentlyContinue; " +
        "if ($null -eq $a) {{ 'ABSENT' }} else {{ " +
        "$gw = ''; $r = @(Get-NetRoute -InterfaceAlias " + qi + " -AddressFamily IPv4 " +
        "-DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue); " +
        "if ($r.Count -gt 0) {{ $gw = $r[0].NextHop }}; " +
        "[pscustomobject]@{{ prefix = [int]($a | Select-Object -First 1).PrefixLength; gateway = \"$gw\" }} " +
        "| ConvertTo-Json -Compress }}"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let iface = param_str(params, "interface", "")
    if iface == "" { return Err("missing 'interface' parameter") }
    let ip = param_str(params, "ip", "")
    if ip == "" { return Err("missing 'ip' parameter") }
    let st = probe(iface, ip)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let m = json::parse(st)?
    if get_int(m, "prefix") != param_int(params, "prefix_length", 0) { return Ok(CheckResult::NotConfigured) }
    let gw = param_str(params, "gateway", "")
    if gw != "" && get_str(m, "gateway") != gw { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let iface = param_str(params, "interface", "")
    if iface == "" { return Err("missing 'interface' parameter") }
    let ip = param_str(params, "ip", "")
    if ip == "" { return Err("missing 'ip' parameter") }
    let qi = ps_q(iface)
    if !want_present(params)? {
        // Drop the address and hand the interface back to DHCP.
        ps_run(
            "$a = Get-NetIPAddress -InterfaceAlias " + qi + " -IPAddress " + ps_q(ip) +
            " -AddressFamily IPv4 -ErrorAction SilentlyContinue; " +
            "if ($a) {{ $a | Remove-NetIPAddress -Confirm:$false }}; " +
            "Set-NetIPInterface -InterfaceAlias " + qi + " -AddressFamily IPv4 -Dhcp Enabled"
        )?
        return Ok(ApplyResult::Success)
    }
    let prefix = param_int(params, "prefix_length", 0)
    if prefix <= 0 || prefix > 32 { return Err("'prefix_length' must be between 1 and 32") }
    let prefix_s = "{prefix}"
    let gw = param_str(params, "gateway", "")
    // Clear the interface's existing IPv4 addresses (keeping automatic
    // link-local ones) and default routes, then lay down the desired address.
    ps_run(
        "$old = @(Get-NetIPAddress -InterfaceAlias " + qi + " -AddressFamily IPv4 -ErrorAction SilentlyContinue | " +
        "Where-Object {{ $_.PrefixOrigin -ne 'WellKnown' }}); " +
        "foreach ($a in $old) {{ $a | Remove-NetIPAddress -Confirm:$false }}; " +
        "$routes = @(Get-NetRoute -InterfaceAlias " + qi + " -AddressFamily IPv4 " +
        "-DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue); " +
        "foreach ($r in $routes) {{ $r | Remove-NetRoute -Confirm:$false }}; " +
        "Set-NetIPInterface -InterfaceAlias " + qi + " -AddressFamily IPv4 -Dhcp Disabled; " +
        "New-NetIPAddress -InterfaceAlias " + qi + " -IPAddress " + ps_q(ip) +
        " -PrefixLength " + prefix_s +
        (if gw != "" { " -DefaultGateway " + ps_q(gw) } else { "" }) +
        " | Out-Null"
    )?
    Ok(ApplyResult::Success)
}
