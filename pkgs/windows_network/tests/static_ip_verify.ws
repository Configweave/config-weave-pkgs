use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; " +
        "$a = Get-NetIPAddress -InterfaceAlias 'Ethernet' -IPAddress '192.0.2.55' -AddressFamily IPv4 -ErrorAction SilentlyContinue; " +
        "$i = Get-NetIPInterface -InterfaceAlias 'Ethernet' -AddressFamily IPv4; " +
        "if ($null -eq $a -and [string]$i.Dhcp -eq 'Enabled') {{ 'OK' }} else {{ 'BAD' }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "OK")
}
