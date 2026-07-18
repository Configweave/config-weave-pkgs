use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; " +
        "$r = Get-NetFirewallRule -Name 'weave-test-8443' -ErrorAction SilentlyContinue; " +
        "if ($r -and [string]$r.Enabled -eq 'True' -and [string]$r.Direction -eq 'Inbound') {{ 'OK' }} else {{ 'BAD' }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "OK")
}
