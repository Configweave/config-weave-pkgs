use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    if fs::read("C:\\weave-files-test\\hello.txt")? != "hello from config-weave" { return Ok(false) }
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; " +
        "$acl = Get-Acl -LiteralPath 'C:\\weave-files-test'; " +
        "$hits = @($acl.Access | Where-Object {{ " +
        "$_.IdentityReference.Value -eq 'BUILTIN\\Users' -and " +
        "[string]$_.AccessControlType -eq 'Allow' -and " +
        "([string]$_.FileSystemRights) -match 'Modify' }}); " +
        "if ($hits.Count -gt 0) {{ 'OK' }} else {{ 'BAD' }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "OK")
}
