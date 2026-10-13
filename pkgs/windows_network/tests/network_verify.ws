use value
use common

// Each rule read back as `name|direction|action|enabled|protocol|ports|remote`.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "Get-NetFirewallRule -Name 'weave-test-*' | Sort-Object Name | ForEach-Object {{ " +
        "$pf = $_ | Get-NetFirewallPortFilter; $af = $_ | Get-NetFirewallAddressFilter; " +
        "$_.Name + '|' + $_.Direction + '|' + $_.Action + '|' + $_.Enabled + '|' + $pf.Protocol + '|' + " +
        "((@($pf.LocalPort) | Sort-Object) -join ',') + '|' + ((@($af.RemoteAddress) | Sort-Object) -join ',') }}")?
    let want = [
        "weave-test-8443|Inbound|Allow|True|TCP|8443|Any",
        "weave-test-icmp|Outbound|Block|False|ICMPv4|Any|Any",
        "weave-test-lists|Inbound|Allow|True|UDP|5353,6000-6010|10.20.30.0/255.255.255.0,10.20.30.40",
    ]
    let got = out.replace("\r", "")
    if got != want.join("\n") { return Err("firewall rules after converge:\n" + got) }
    Ok(true)
}
