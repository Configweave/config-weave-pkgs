use value
use common

// One line per feature: "<name>=<state>", from the cmdlet that owns it.
fn states() -> Result[string, string] {
    let script = "'Telnet-Client=' + (Get-WindowsFeature -Name Telnet-Client).InstallState\n" +
        "'SNMP-Service=' + (Get-WindowsFeature -Name SNMP-Service).InstallState\n" +
        "'RSAT-SNMP=' + (Get-WindowsFeature -Name RSAT-SNMP).InstallState\n" +
        "'TFTP=' + (Get-WindowsOptionalFeature -Online -FeatureName TFTP).State\n" +
        "'SimpleTCP=' + (Get-WindowsOptionalFeature -Online -FeatureName SimpleTCP).State\n" +
        "'OpenSSH.Server=' + (Get-WindowsCapability -Online -Name 'OpenSSH.Server~~~~0.0.1.0').State\n"
    let out = common::run_ps(script, #{})?
    if !out.success { return Err(common::failure("reading feature states", out)) }
    Ok(out.stdout)
}

fn verify(facts: Value) -> Result[bool, string] {
    let got = states()?
    for want in ["Telnet-Client=Installed", "SNMP-Service=Installed", "RSAT-SNMP=Installed", "TFTP=Enabled", "SimpleTCP=Disabled", "OpenSSH.Server=NotPresent"] {
        if !got.contains(want) { return Err("expected " + want + ", got: " + got.trim().replace("\r\n", ", ").replace("\n", ", ")) }
    }
    Ok(true)
}
