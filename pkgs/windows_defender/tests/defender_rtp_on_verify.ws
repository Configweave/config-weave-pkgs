use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify", "[string][bool](Get-MpComputerStatus).RealTimeProtectionEnabled")?
    if out != "True" { return Err("RealTimeProtectionEnabled is " + out) }
    Ok(true)
}
