use value
use common

// The change is recorded and waiting for its reboot, and a check run
// reports exactly that.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        common::pending_ps("workgroup_member") +
        "$wg = (Get-CimInstance Win32_ComputerSystem).Workgroup; " +
        "if (-not $pending) {{ 'no pending reboot is recorded' }} elseif ($wg -ne 'TESTWG') {{ 'workgroup is ' + $wg }}")?
    if out != "" { return Err(out) }
    Ok(true)
}
