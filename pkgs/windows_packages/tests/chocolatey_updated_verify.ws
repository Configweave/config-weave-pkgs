use value
use common

// Inspect real Chocolatey state after the harness has exercised check/apply,
// its second apply and the final check. The fixture's install script records
// attempts, so a fresh window or repeated apply cannot silently upgrade again.
fn verify(facts: Value) -> Result[bool, string] {
    let script = common::choco_ps() +
        "$d = 'C:\\cw-choco-updated'\n" +
        "$stamp = 'C:\\ProgramData\\config-weave\\chocolatey-updated'\n" +
        "$mode = (Get-Content ($d + '\\mode') -Raw).Trim()\n" +
        "$before = (Get-Content ($d + '\\before') -Raw).Trim()\n" +
        "$unchanged = $mode -eq 'fresh' -or $mode -eq 'failure'\n" +
        "$version = if ($unchanged) {{ '1.0.0' }} else {{ '2.0.0' }}\n" +
        "$listed = @(& $choco list --limit-output @chocoLocal)\n" +
        "if ($LASTEXITCODE -ne 0 -or $listed -notcontains ('cw-updated|' + $version)) {{ throw ('wrong installed version: ' + ($listed -join ',')) }}\n" +
        "$marker = (Get-Content ($d + '\\installed') -Raw).Trim()\n" +
        // Failure may execute a package's script but must not commit version 2.
        "if ($mode -ne 'failure' -and $marker -ne $version) {{ throw 'wrong install marker' }}\n" +
        "$attempts = @(Get-Content ($d + '\\attempts') -ErrorAction SilentlyContinue)\n" +
        "if ($mode -eq 'fresh') {{ if ($attempts.Count -ne 0) {{ throw 'fresh window invoked upgrade' }} }} else {{ if ($attempts.Count -lt 1) {{ throw 'upgrade was never attempted' }}; if ($mode -ne 'failure' -and $attempts.Count -ne 1) {{ throw 'upgrade repeated after success' }} }}\n" +
        "if (-not (Test-Path -LiteralPath $stamp)) {{ throw 'stamp missing' }}\n" +
        "$item = Get-Item -LiteralPath $stamp\n" +
        "$content = (Get-Content -LiteralPath $stamp -Raw).Trim()\n" +
        "if ($unchanged) {{ if ($content -ne 'sentinel' -or [string]$item.LastWriteTimeUtc.Ticks -ne $before) {{ throw 'stamp refreshed without successful upgrade' }} }} else {{ if ($content -ne 'chocolatey' -or $item.LastWriteTimeUtc -lt [DateTime]::UtcNow.AddMinutes(-30)) {{ throw 'success did not write fresh stamp' }}; if ($before -ne 'missing' -and $item.LastWriteTimeUtc.Ticks -le [long]$before) {{ throw 'stale stamp was not advanced' }} }}\n"
    let out = common::query(script, #{})?
    if !out.success { return Err(common::failure("verifying chocolatey_updated", out)) }
    Ok(true)
}
