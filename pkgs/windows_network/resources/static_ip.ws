use value
use common

struct Spec {
    iface: string,
    ip: string,
    family: string,
    prefix: int,
    gateway: string,
}

fn spec(params: Value) -> Result[Spec, string] {
    let iface = common::param_str(params, "interface", "")
    common::no_wildcards("interface", iface)?
    let ip = common::param_str(params, "ip", "")
    if ip == "" { return Err("missing 'ip' parameter") }
    let family = common::family_of("ip", ip)?
    let prefix = common::param_int(params, "prefix_length", 0)
    let max = if family == "IPv4" { 32 } else { 128 }
    if prefix < 1 || prefix > max { return Err("'prefix_length' must be between 1 and {max} for an " + family + " address") }
    let gateway = common::param_str(params, "gateway", "")
    if gateway != "" && common::family_of("gateway", gateway)? != family {
        return Err("'gateway' " + gateway + " is not an " + family + " address like 'ip'")
    }
    Ok(Spec { iface: iface, ip: ip, family: family, prefix: prefix, gateway: gateway })
}

fn default_prefix(family: string) -> string { if family == "IPv4" { "0.0.0.0/0" } else { "::/0" } }

// PowerShell binding, for the interface and the address family of 'ip':
//   $want    the canonical address; $mine its entry on the interface, if any
//   $others  every other manually configured address of the family
//   $routes  the interface's active default routes; $hops their next hops,
//            leaving out router-advertised IPv6 ones
//   $phops   the next hops of its persistent (manually added) default routes,
//            which Windows re-activates later, at reboot or when an address
//            in their subnet comes back
//   $dhcp    the interface's Dhcp state for the family
//   $gw      the canonical gateway, or '' when 'gateway' is unset
// Addresses are compared in [ipaddress] canonical form, without any %scope.
fn load(s: Spec) -> string {
    "function Canon($a) {{ ([ipaddress](([string]$a) -replace '%.*$', '')).ToString() }}; " +
    common::iface_ps(s.iface) +
    "$fam = '" + s.family + "'; $dr = '" + default_prefix(s.family) + "'; " +
    "$want = Canon " + common::ps_q(s.ip) + "; " +
    "$gw = " + (if s.gateway != "" { "Canon " + common::ps_q(s.gateway) } else { "''" }) + "; " +
    "$all = @(Get-NetIPAddress -InterfaceIndex $ifx -AddressFamily $fam -ErrorAction SilentlyContinue); " +
    "$mine = @($all | Where-Object {{ (Canon $_.IPAddress) -eq $want }}) | Select-Object -First 1; " +
    "$others = @($all | Where-Object {{ [string]$_.PrefixOrigin -eq 'Manual' -and (Canon $_.IPAddress) -ne $want }}); " +
    "function DefRoutes($store) {{ @(Get-NetRoute -InterfaceIndex $ifx -AddressFamily $fam -DestinationPrefix $dr -PolicyStore $store -ErrorAction SilentlyContinue) }}; " +
    // A manually added route is the one kept in the persistent store; an
    // active route from DHCP is reported with the same NetMgmt protocol, so
    // the protocol cannot tell them apart. DropRoutes removes the manual
    // default routes not through $keep, and with a gateway to keep, every
    // other active one except router-advertised IPv6 routes.
    "function DropRoutes($keep) {{ " +
    "$p = @(DefRoutes 'PersistentStore'); $static = @($p | ForEach-Object {{ Canon $_.NextHop }}); " +
    "$p | Where-Object {{ (Canon $_.NextHop) -ne $keep }} | Remove-NetRoute -Confirm:$false; " +
    "DefRoutes 'ActiveStore' | Where-Object {{ $h = Canon $_.NextHop; $h -ne $keep -and ($static -contains $h -or ($keep -ne '' -and [string]$_.Protocol -ne 'RouterAdvertisement')) }} | Remove-NetRoute -Confirm:$false }}; " +
    "$routes = DefRoutes 'ActiveStore'; " +
    "$hops = @($routes | Where-Object {{ [string]$_.Protocol -ne 'RouterAdvertisement' }} | ForEach-Object {{ Canon $_.NextHop }}); " +
    "$phops = @(DefRoutes 'PersistentStore' | ForEach-Object {{ Canon $_.NextHop }}); " +
    "$dhcp = [string](Get-NetIPInterface -InterfaceIndex $ifx -AddressFamily $fam).Dhcp; "
}

// A JSON object { origin, prefix, others, gw_ok, static_hops, dhcp }.
fn probe(s: Spec) -> Result[Value, string] {
    let out = common::ps("reading " + s.family + " addresses on '" + s.iface + "'",
        load(s) +
        "[pscustomobject]@{{ " +
        "origin = $(if ($mine) {{ [string]$mine.PrefixOrigin }} else {{ '' }}); " +
        "prefix = $(if ($mine) {{ [int]$mine.PrefixLength }} else {{ 0 }}); " +
        "others = @($others | ForEach-Object {{ Canon $_.IPAddress }}); " +
        // Exactly one default route on this interface, through the gateway.
        // and the same route, and no other, kept in the persistent store.
        "gw_ok = ($gw -eq '' -or (($hops -join ',') -eq $gw -and (@($phops | Sort-Object -Unique) -join ',') -eq $gw)); " +
        "static_hops = $phops; " +
        "dhcp = $dhcp }} | ConvertTo-Json -Compress")?
    common::parse(out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let s = spec(params)?
    let m = probe(s)?
    let manual = common::get_str(m, "origin") == "Manual"
    let others = common::get_list(m, "others")
    if !common::want_present(params)? {
        if manual { return Ok(CheckResult::NotConfigured) }
        // The last manual address gone means the interface is back on
        // automatic configuration, with no static default route left over.
        // While other manual addresses remain (another static_ip step owns
        // them), the interface's DHCP state is theirs to decide.
        if others.is_empty() {
            if s.family == "IPv4" && common::get_str(m, "dhcp") != "Enabled" { return Ok(CheckResult::NotConfigured) }
            if !common::get_list(m, "static_hops").is_empty() { return Ok(CheckResult::NotConfigured) }
        }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // A DHCP lease of the same address is not a static address.
    if !manual { return Ok(CheckResult::NotConfigured) }
    if common::get_int(m, "prefix") != s.prefix { return Ok(CheckResult::NotConfigured) }
    if s.family == "IPv4" && common::get_str(m, "dhcp") != "Disabled" { return Ok(CheckResult::NotConfigured) }
    if common::param_bool(params, "exclusive", false) && !others.is_empty() { return Ok(CheckResult::NotConfigured) }
    if !common::get_bool(m, "gw_ok") { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let s = spec(params)?
    if !common::want_present(params)? {
        common::ps("removing " + s.ip + " from '" + s.iface + "'",
            load(s) +
            // Static routes go first, while they are still active: once the
            // last address in their subnet is gone Windows only hides an
            // active route, and brings it back with the next address there.
            "if ($others.Count -eq 0) {{ DropRoutes '' }}; " +
            "if ($mine -and [string]$mine.PrefixOrigin -eq 'Manual') {{ Remove-NetIPAddress -InterfaceIndex $ifx -IPAddress $want -Confirm:$false }}; " +
            "if ($others.Count -eq 0 -and $fam -eq 'IPv4' -and $dhcp -ne 'Enabled') {{ Set-NetIPInterface -InterfaceIndex $ifx -AddressFamily IPv4 -Dhcp Enabled }}")?
        return Ok(ApplyResult::Success)
    }
    // Only what differs is changed: the address is added (or re-added with
    // the right prefix) on its own, other addresses stay unless 'exclusive',
    // and routes are only touched when 'gateway' is set.
    let exclusive = if common::param_bool(params, "exclusive", false) {
        "foreach ($o in $others) {{ Remove-NetIPAddress -InterfaceIndex $ifx -IPAddress $o.IPAddress -Confirm:$false }}; "
    } else { "" }
    let route = if s.gateway != "" {
        "DropRoutes $gw; " +
        "if ($hops -notcontains $gw -or $phops -notcontains $gw) {{ " +
        "foreach ($st in 'ActiveStore', 'PersistentStore') {{ DefRoutes $st | Remove-NetRoute -Confirm:$false }}; " +
        "New-NetRoute -InterfaceIndex $ifx -AddressFamily $fam -DestinationPrefix $dr -NextHop $gw | Out-Null }}; "
    } else { "" }
    common::ps("setting " + s.ip + "/{s.prefix} on '" + s.iface + "'",
        load(s) +
        // A manual IPv4 address needs DHCP off; turning it off drops a leased
        // address, so the address is looked up again afterwards.
        "if ($fam -eq 'IPv4' -and $dhcp -ne 'Disabled') {{ Set-NetIPInterface -InterfaceIndex $ifx -AddressFamily IPv4 -Dhcp Disabled; " +
        "$mine = @(Get-NetIPAddress -InterfaceIndex $ifx -AddressFamily $fam -ErrorAction SilentlyContinue | Where-Object {{ (Canon $_.IPAddress) -eq $want }}) | Select-Object -First 1 }}; " +
        "if ($mine -and ([string]$mine.PrefixOrigin -ne 'Manual' -or [int]$mine.PrefixLength -ne {s.prefix})) {{ " +
        "Remove-NetIPAddress -InterfaceIndex $ifx -IPAddress $want -Confirm:$false; $mine = $null }}; " +
        "if (-not $mine) {{ New-NetIPAddress -InterfaceIndex $ifx -AddressFamily $fam -IPAddress $want -PrefixLength {s.prefix} | Out-Null }}; " +
        exclusive + route)?
    Ok(ApplyResult::Success)
}
