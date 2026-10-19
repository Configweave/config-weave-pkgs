use value
use common

// Mount state and letters, the extracted trees, their markers, and that an
// image the extract mounted itself was dismounted again.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::run_ps(
        "$bad = New-Object System.Collections.Generic.List[string]\n" +
        "function Img($n) {{ Get-DiskImage -ImagePath ('C:\\weave-iso\\' + $n + '.iso') }}\n" +
        "if (-not (Img 'a').Attached) {{ $bad.Add('a.iso is not mounted') }} elseif ([string]((Img 'a') | Get-Volume).DriveLetter -ne 'S') {{ $bad.Add('a.iso is not at S:') }}\n" +
        "if ((Img 'b').Attached) {{ $bad.Add('b.iso was left mounted by the extract') }}\n" +
        "if (-not (Img 'c').Attached) {{ $bad.Add('c.iso is not mounted') }}\n" +
        "foreach ($t in @(@('a', 'a'), @('b', 'b'), @('c', 'a'))) {{\n" +
        "  $d = 'C:\\weave-media\\' + $t[0]\n" +
        "  $setup = Join-Path $d 'setup.txt'\n" +
        "  if (-not (Test-Path -LiteralPath $setup)) {{ $bad.Add($setup + ' is missing'); continue }}\n" +
        "  if ((Get-Content -LiteralPath $setup -Raw).Trim() -ne ('media ' + $t[1])) {{ $bad.Add($setup + ' holds ' + (Get-Content -LiteralPath $setup -Raw)) }}\n" +
        "  if ((Get-Item -LiteralPath $setup).IsReadOnly) {{ $bad.Add($setup + ' is read-only') }}\n" +
        "  if (-not (Test-Path -LiteralPath (Join-Path $d 'sub\\deep\\file.txt'))) {{ $bad.Add($d + ' lacks sub\\deep\\file.txt') }}\n" +
        "  $iso = Get-Item -LiteralPath ('C:\\weave-iso\\' + $t[1] + '.iso')\n" +
        "  $m = (Get-Content -LiteralPath (Join-Path $d '.config-weave-iso') -Raw).Trim()\n" +
        "  if (-not $m.StartsWith('c:\\weave-iso\\' + $t[1] + '.iso|' + $iso.Length + '|')) {{ $bad.Add($d + ' marker reads ' + $m) }}\n" +
        "}}\n" +
        "if (Test-Path -LiteralPath 'C:\\weave-media\\b\\stray.txt') {{ $bad.Add('the stray file in b survived the mirror') }}\n" +
        "$bad -join '; '\n"
    )?
    if !out.success { return Err(common::failure("verify", out)) }
    let problems = out.stdout.trim()
    if problems != "" { return Err(problems) }
    Ok(true)
}
