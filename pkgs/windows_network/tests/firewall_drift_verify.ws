use value
use common

// Each drift-test rule as `name|action|enabled|protocol|ports|profile|remote`,
// read back after the converge; the expected spellings are Windows' own.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "Get-NetFirewallRule -Name 'weave-drift-*' | Sort-Object Name | ForEach-Object {{ " +
        "$pf = $_ | Get-NetFirewallPortFilter; $af = $_ | Get-NetFirewallAddressFilter; " +
        "$_.Name + '|' + $_.Action + '|' + $_.Enabled + '|' + $pf.Protocol + '|' + (@($pf.LocalPort) -join ',') + '|' + $_.Profile + '|' + ((@($af.RemoteAddress) | Sort-Object) -join ',') }}")?
    let want = [
        "weave-drift-action|Block|True|TCP|5006|Any|Any",
        "weave-drift-cidr|Allow|True|TCP|5008|Any|10.1.2.0/255.255.255.0,10.1.2.3",
        "weave-drift-enabled|Allow|False|TCP|5007|Any|Any",
        "weave-drift-icmp|Allow|True|ICMPv4|Any|Any|Any",
        "weave-drift-port|Allow|True|TCP|1433|Any|Any",
        "weave-drift-profile|Allow|True|TCP|5002|Domain, Private|Any",
        "weave-drift-protocol|Allow|True|TCP|5001|Any|Any",
        "weave-drift-remote|Allow|True|TCP|5003|Any|192.168.50.0/255.255.255.0",
        "weave-drift-remote-any|Allow|True|TCP|5004|Any|Any",
    ]
    let got = out.replace("\r", "")
    if got != want.join("\n") { return Err("firewall rules after converge:\n" + got) }
    Ok(true)
}
