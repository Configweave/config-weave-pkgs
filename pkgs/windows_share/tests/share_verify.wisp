use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    if !fs::is_dir("C:\\weave-share-test") { return Ok(false) }
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; " +
        "$s = Get-SmbShare -Name 'weave-data' -ErrorAction SilentlyContinue; " +
        "$acc = @(Get-SmbShareAccess -Name 'weave-data' -ErrorAction SilentlyContinue | " +
        "Where-Object {{ $_.AccountName.ToLower().EndsWith('administrators') -and [string]$_.AccessRight -eq 'Full' }}); " +
        "if ($s -and $s.Path -eq 'C:\\weave-share-test' -and $acc.Count -gt 0) {{ 'OK' }} else {{ 'BAD' }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "OK")
}
