use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$p = Get-MpPreference; $bad = @(); " +
        "if ([int]$p.ScanScheduleDay -ne 0) {{ $bad += ('ScanScheduleDay is ' + $p.ScanScheduleDay) }}; " +
        "if ($p.ScanScheduleQuickScanTime -ne [TimeSpan]::Zero) {{ $bad += ('ScanScheduleQuickScanTime is ' + $p.ScanScheduleQuickScanTime) }}; " +
        "if ([int]$p.ScanAvgCPULoadFactor -ne 50) {{ $bad += ('ScanAvgCPULoadFactor is ' + $p.ScanAvgCPULoadFactor) }}; " +
        "if (@($p.ProxyBypass | Where-Object {{ $_ }}).Count -ne 0) {{ $bad += ('ProxyBypass is ' + (@($p.ProxyBypass) -join ',')) }}; " +
        "if ($p.CheckForSignaturesBeforeRunningScan -ne $false) {{ $bad += 'CheckForSignaturesBeforeRunningScan is still set' }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
