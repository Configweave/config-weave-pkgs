use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    let out = common::run_ps("(Get-WindowsFeature -Name Telnet-Client).InstallState.ToString()", #{})?
    if !out.success { return Err(common::failure("reading Telnet-Client", out)) }
    let st = out.stdout.trim()
    if st != "Available" && st != "Removed" { return Err("Telnet-Client is " + st + ", expected removed") }
    Ok(true)
}
