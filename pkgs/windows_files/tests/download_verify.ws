use value
use common

// Sizes and digests of the downloads, nothing left half-written, and the
// replaced file still carrying its explicit Guests rule.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::run_ps(
        "$bad = New-Object System.Collections.Generic.List[string]\n" +
        "$want = '646B43B5D718913D6211E2C18B2B3B667CF6EAA76A2493E55B1DE5CA04C2578E'\n" +
        "foreach ($n in 'size', 'truncated', 'fresh', 'keep') {{\n" +
        "  $p = 'C:\\weave-dl\\' + $n + '.txt'\n" +
        "  if (-not (Test-Path -LiteralPath $p)) {{ $bad.Add($p + ' is missing'); continue }}\n" +
        "  if ((Get-FileHash -LiteralPath $p -Algorithm SHA256).Hash -ne $want) {{ $bad.Add($p + ' has the wrong content') }}\n" +
        "}}\n" +
        "foreach ($p in 'C:\\weave-dl\\wrong-size.txt', 'C:\\weave-dl\\content.txt') {{ if (Test-Path -LiteralPath $p) {{ $bad.Add($p + ' should not exist') }} }}\n" +
        "$tmp = @(Get-ChildItem -LiteralPath 'C:\\weave-dl' -Filter '*.config-weave-download' | ForEach-Object {{ $_.Name }})\n" +
        "if ($tmp.Count -gt 0) {{ $bad.Add('temp files left behind: ' + ($tmp -join ', ')) }}\n" +
        "$guests = @((Get-Item -LiteralPath 'C:\\weave-dl\\keep.txt').GetAccessControl('Access').GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier]) | Where-Object {{ $_.IdentityReference.Value -eq 'S-1-5-32-546' }})\n" +
        "if ($guests.Count -eq 0) {{ $bad.Add('keep.txt lost its explicit Guests rule') }}\n" +
        "$bad -join '; '\n"
    )?
    if !out.success { return Err(common::failure("verify", out)) }
    let problems = out.stdout.trim()
    if problems != "" { return Err(problems) }
    Ok(true)
}
