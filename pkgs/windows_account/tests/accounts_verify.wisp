use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; " +
        "$u = Get-LocalUser -Name 'weave-svc' -ErrorAction SilentlyContinue; " +
        "$hits = @(Get-LocalGroupMember -Group 'weave-ops' -ErrorAction SilentlyContinue | " +
        "Where-Object {{ $_.Name.ToLower().EndsWith('\\weave-svc') }}); " +
        "if ($u -and [bool]$u.Enabled -and $hits.Count -gt 0) {{ 'OK' }} else {{ 'BAD' }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "OK")
}
