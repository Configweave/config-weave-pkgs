use value
use common

// No manual IPv4 address and no manually added default route is left on
// Ethernet, and it is back on DHCP.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$bad = @(); " +
        "$m4 = @(Get-NetIPAddress -InterfaceAlias 'Ethernet' -AddressFamily IPv4 -PrefixOrigin Manual -ErrorAction SilentlyContinue | ForEach-Object {{ $_.IPAddress }}); " +
        "if ($m4.Count -gt 0) {{ $bad += ('manual IPv4 addresses left: ' + ($m4 -join ',')) }}; " +
        "if ([string](Get-NetIPInterface -InterfaceAlias 'Ethernet' -AddressFamily IPv4).Dhcp -ne 'Enabled') {{ $bad += 'DHCP is still off' }}; " +
        "$h = @(Get-NetRoute -InterfaceAlias 'Ethernet' -DestinationPrefix '0.0.0.0/0' -PolicyStore PersistentStore -ErrorAction SilentlyContinue | ForEach-Object {{ $_.NextHop }}); " +
        "if ($h.Count -gt 0) {{ $bad += ('static default routes left: ' + ($h -join ',')) }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
