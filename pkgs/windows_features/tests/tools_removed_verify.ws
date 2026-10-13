use value
use common

// The removal finishes at the next reboot, so both the feature and its
// tool must at least be pending removal.
fn verify(facts: Value) -> Result[bool, string] {
    for name in ["SNMP-Service", "RSAT-SNMP"] {
        let out = common::run_ps("(Get-WindowsFeature -Name $env:CW_NAME).InstallState.ToString()", #{ "CW_NAME": Value::String(name) })?
        if !out.success { return Err(common::failure("reading " + name, out)) }
        let st = out.stdout.trim()
        if st != "UninstallPending" && st != "Available" && st != "Removed" { return Err(name + " is " + st + ", expected removed or pending removal") }
    }
    Ok(true)
}
