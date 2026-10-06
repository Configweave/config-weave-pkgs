use value
use shell

// Each drift-test rule as `name|protocol|ports|profile|remote`, read back
// after the converge; the expected spellings are Windows' own.
fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; " +
        "Get-NetFirewallRule -Name 'weave-drift-*' | Sort-Object Name | ForEach-Object {{ " +
        "$pf = $_ | Get-NetFirewallPortFilter; $af = $_ | Get-NetFirewallAddressFilter; " +
        "$_.Name + '|' + $pf.Protocol + '|' + (@($pf.LocalPort) -join ',') + '|' + $_.Profile + '|' + (@($af.RemoteAddress) -join ',') }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    let want = [
        "weave-drift-port|TCP|1433|Any|Any",
        "weave-drift-profile|TCP|5002|Domain, Private|Any",
        "weave-drift-protocol|TCP|5001|Any|Any",
        "weave-drift-remote|TCP|5003|Any|192.168.50.0/255.255.255.0",
        "weave-drift-remote-any|TCP|5004|Any|Any",
    ]
    let got = out.stdout.trim().replace("\r", "")
    if got != want.join("\n") { return Err("firewall rules after converge:\n" + got) }
    Ok(true)
}
