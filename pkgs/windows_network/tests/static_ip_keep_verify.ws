use value
use common

// 192.0.2.10 is gone; 192.0.2.11, its persistent route and DHCP-off remain.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$bad = @(); " +
        "$m4 = @(Get-NetIPAddress -InterfaceAlias 'Ethernet' -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | ForEach-Object {{ $_.IPAddress }}); " +
        "if (($m4 -join ',') -ne '192.0.2.11') {{ $bad += ('manual IPv4 addresses: ' + ($m4 -join ',')) }}; " +
        "if ([string](Get-NetIPInterface -InterfaceAlias 'Ethernet' -AddressFamily IPv4).Dhcp -ne 'Disabled') {{ $bad += 'DHCP was turned back on' }}; " +
        "$h = @(Get-NetRoute -InterfaceAlias 'Ethernet' -DestinationPrefix '0.0.0.0/0' -PolicyStore PersistentStore -ErrorAction SilentlyContinue | ForEach-Object {{ $_.NextHop }}); " +
        "if (($h -join ',') -ne '192.0.2.1') {{ $bad += ('persistent default routes: ' + ($h -join ',')) }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
