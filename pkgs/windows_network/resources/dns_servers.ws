use value
use common

fn validate(params: Value) -> Result[string, string] {
    let iface = common::param_str(params, "interface", "")
    common::no_wildcards("interface", iface)?
    for s in common::param_list(params, "servers") {
        common::family_of("servers", s)?
    }
    Ok(iface)
}

// PowerShell binding $v4 and $v6 to the interface's *static* DNS servers, in
// order, read from the NameServer values the TCP/IP stacks keep per
// interface. Get-DnsClientServerAddress reports the effective list, which
// includes servers DHCP handed out, so it cannot tell "static" from
// "DHCP-assigned" (the same trap as issue 29).
fn static_ps(iface: string) -> string {
    "function Canon($a) {{ ([ipaddress](([string]$a) -replace '%.*$', '')).ToString() }}; " +
    common::iface_ps(iface) +
    "$guid = (Get-NetAdapter -InterfaceIndex $ifx).InterfaceGuid; " +
    "function NS($stack) {{ " +
    "$k = 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\' + $stack + '\\Parameters\\Interfaces\\' + $guid; " +
    "$v = (Get-ItemProperty -Path $k -Name NameServer -ErrorAction SilentlyContinue).NameServer; " +
    "@(([string]$v) -split '[^0-9A-Fa-f:.%]+' | Where-Object {{ $_ }} | ForEach-Object {{ Canon $_ }}) }}; " +
    "$v4 = NS 'Tcpip'; $v6 = NS 'Tcpip6'; "
}

// The wanted servers as canonical v4 and v6 lists, joined by ','. Order is
// kept within each family: it is the resolver's preference order.
fn wanted_ps(servers: List[string]) -> string {
    (if servers.is_empty() { "$want = @(); " } else { "$want = @(" + common::ps_list(servers) + " | ForEach-Object {{ Canon $_ }}); " }) +
    "$w4 = @($want | Where-Object {{ ([ipaddress]$_).AddressFamily -eq 'InterNetwork' }}); " +
    "$w6 = @($want | Where-Object {{ ([ipaddress]$_).AddressFamily -eq 'InterNetworkV6' }}); " +
    "$same = (($w4 -join ',') -eq ($v4 -join ',')) -and (($w6 -join ',') -eq ($v6 -join ',')); "
}

fn check(params: Value) -> Result[CheckResult, string] {
    let iface = validate(params)?
    let st = common::ps("reading the DNS servers of '" + iface + "'",
        static_ps(iface) + wanted_ps(common::param_list(params, "servers")) +
        "if ($same) {{ 'MATCH' }} else {{ 'DIFF' }}")?
    if st == "MATCH" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let iface = validate(params)?
    // An empty list removes the static servers, handing the interface back
    // to whatever DHCP or router advertisements supply.
    common::ps("setting the DNS servers of '" + iface + "'",
        static_ps(iface) + wanted_ps(common::param_list(params, "servers")) +
        "if (-not $same) {{ " +
        "Set-DnsClientServerAddress -InterfaceIndex $ifx -ResetServerAddresses; " +
        "if ($want.Count -gt 0) {{ Set-DnsClientServerAddress -InterfaceIndex $ifx -ServerAddresses $want }} }}")?
    Ok(ApplyResult::Success)
}
