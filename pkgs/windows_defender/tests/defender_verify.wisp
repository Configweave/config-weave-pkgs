use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; " +
        "$p = @((Get-MpPreference).ExclusionPath); " +
        "if ($p -contains 'C:\\weave-defender-test') {{ 'OK' }} else {{ 'BAD' }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "OK")
}
