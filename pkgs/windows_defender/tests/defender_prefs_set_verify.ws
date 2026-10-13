use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    let out = common::ps("verify",
        "$p = Get-MpPreference; $bad = @(); " +
        "if ([int]$p.ScanScheduleDay -ne 7) {{ $bad += ('ScanScheduleDay is ' + $p.ScanScheduleDay) }}; " +
        "if ($p.ScanScheduleQuickScanTime -ne [TimeSpan]'03:30:00') {{ $bad += ('ScanScheduleQuickScanTime is ' + $p.ScanScheduleQuickScanTime) }}; " +
        "if ([int]$p.ScanAvgCPULoadFactor -ne 40) {{ $bad += ('ScanAvgCPULoadFactor is ' + $p.ScanAvgCPULoadFactor) }}; " +
        "if (((@($p.ProxyBypass) | Sort-Object) -join ',') -ne 'weave-a.example,weave-b.example') {{ $bad += ('ProxyBypass is ' + (@($p.ProxyBypass) -join ',')) }}; " +
        "if ($p.CheckForSignaturesBeforeRunningScan -ne $true) {{ $bad += 'CheckForSignaturesBeforeRunningScan is not set' }}; " +
        "$bad -join '; '")?
    if out != "" { return Err(out) }
    Ok(true)
}
