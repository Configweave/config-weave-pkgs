use value
use common

// 192.0.2.20/24 is the only manual IPv4 address, DHCP is off, the default
// route is 192.0.2.1 alone in both stores, and fd00:77::20/64 is set.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$bad = @(); " +
        "$m4 = @(Get-NetIPAddress -InterfaceAlias 'Ethernet' -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | ForEach-Object {{ $_.IPAddress + '/' + $_.PrefixLength }}); " +
        "if (($m4 -join ',') -ne '192.0.2.20/24') {{ $bad += ('manual IPv4 addresses: ' + ($m4 -join ',')) }}; " +
        "if ([string](Get-NetIPInterface -InterfaceAlias 'Ethernet' -AddressFamily IPv4).Dhcp -ne 'Disabled') {{ $bad += 'DHCP is on' }}; " +
        "foreach ($st in 'ActiveStore', 'PersistentStore') {{ " +
        "$h = @(Get-NetRoute -InterfaceAlias 'Ethernet' -DestinationPrefix '0.0.0.0/0' -PolicyStore $st -ErrorAction SilentlyContinue | ForEach-Object {{ $_.NextHop }}); " +
        "if (($h -join ',') -ne '192.0.2.1') {{ $bad += ($st + ' default routes: ' + ($h -join ',')) }} }}; " +
        "$v6 = Get-NetIPAddress -InterfaceAlias 'Ethernet' -IPAddress 'fd00:77::20' -ErrorAction SilentlyContinue; " +
        "if (-not $v6 -or [string]$v6.PrefixOrigin -ne 'Manual' -or $v6.PrefixLength -ne 64) {{ $bad += 'fd00:77::20/64 is not a manual address' }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
