use value
use common

fn verify(facts: Value) -> Result[bool, string] {
    let out = common::run_ps(
        "$bad = New-Object System.Collections.Generic.List[string]\n" +
        "$a = Get-DiskImage -ImagePath 'C:\\weave-iso\\a.iso'\n" +
        "if (-not $a.Attached -or [string]($a | Get-Volume).DriveLetter -ne 'T') {{ $bad.Add('a.iso is not mounted at T:') }}\n" +
        "if (Test-Path -LiteralPath 'S:\\') {{ $bad.Add('S: still exists') }}\n" +
        "if ((Get-DiskImage -ImagePath 'C:\\weave-iso\\c.iso').Attached) {{ $bad.Add('c.iso is still mounted') }}\n" +
        "if (Test-Path -LiteralPath 'C:\\weave-media\\c') {{ $bad.Add('C:\\weave-media\\c still exists') }}\n" +
        "$bad -join '; '\n"
    )?
    if !out.success { return Err(common::failure("verify", out)) }
    let problems = out.stdout.trim()
    if problems != "" { return Err(problems) }
    Ok(true)
}
