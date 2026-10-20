// remove_parts: a copy of a VSIX without some of its parts, for an
// extension whose nested dependency is older than one already installed
// (VSIXInstaller refuses to put the older nested copy over the newer one,
// even when the newer one meets the dependency's version range).
use value
use path
use hash
use common

fn validate(parts: List[string]) -> Result[unit, string] {
    for p in parts {
        common::single_line("remove_parts", p)?
        let n = p.replace("\\", "/")
        let segs = n.split("/").filter(|s| s != "")
        if segs.is_empty() { return Err("'remove_parts' entries must name a part such as /Shared/Nested.vsix, got '" + p + "'") }
        if segs.any(|s| s == "." || s == "..") { return Err("'remove_parts' entries must not contain '.' or '..' segments, got '" + p + "'") }
        if segs.get(0).unwrap_or("").to_lower() == "extension.vsixmanifest" && segs.len() == 1 {
            return Err("'remove_parts' cannot remove extension.vsixmanifest")
        }
    }
    Ok(())
}

// The part names, normalised: "/Shared/Nested.vsix".
fn names(parts: List[string]) -> List[string] {
    parts.map(|p| "/" + p.replace("\\", "/").split("/").filter(|s| s != "").join("/"))
}

// Writes a copy of `src` into the cache with every part in `parts`
// deleted, and returns its path. The copy is opened with
// System.IO.Packaging, because VSIXInstaller cannot open a package that
// System.IO.Compression has rewritten. Before the parts go:
//   - every package signature is removed (it no longer matches);
// after:
//   - extension.vsixmanifest loses each Location attribute that pointed at
//     a removed part (the dependency itself stays, so an installed copy
//     still has to satisfy it) and each Asset whose Path was removed;
//   - manifest.json drops the removed files and gets fresh SHA-256 values
//     for every file that remains.
fn strip(src: string, parts: List[string]) -> Result[string, string] {
    let wanted = names(parts)
    let dir = path::join(common::cache_dir(), "stripped\\" + hash::sha256(src + "|" + wanted.join("|")).slice(0, 16))
    let dst = path::join(dir, path::filename(src))
    let script = "Add-Type -AssemblyName WindowsBase\n" +
        "$null = New-Item -ItemType Directory -Force -Path (Split-Path -LiteralPath $env:CW_DST)\n" +
        "Copy-Item -LiteralPath $env:CW_SRC -Destination $env:CW_DST -Force\n" +
        "$want = @($env:CW_PARTS -split [char]10 | Where-Object {{ $_ }})\n" +
        "function PartUri([string]$n) {{ [IO.Packaging.PackUriHelper]::CreatePartUri((New-Object Uri($n.TrimStart('/'), [UriKind]::Relative))) }}\n" +
        "function Norm([string]$v) {{ '/' + ((($v -replace '\\\\', '/').Split('/') | Where-Object {{ $_ }}) -join '/') }}\n" +
        "$pkg = [IO.Packaging.Package]::Open($env:CW_DST, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)\n" +
        "try {{\n" +
        "  $sig = New-Object IO.Packaging.PackageDigitalSignatureManager($pkg)\n" +
        "  if ($sig.IsSigned) {{ $sig.RemoveAllSignatures() }}\n" +
        "  foreach ($n in $want) {{\n" +
        "    $u = PartUri $n\n" +
        "    if (-not $pkg.PartExists($u)) {{ throw ('the VSIX has no part ' + $n + ' to remove') }}\n" +
        "    $pkg.DeletePart($u)\n" +
        "  }}\n" +
        "  $mp = $pkg.GetPart((PartUri 'extension.vsixmanifest'))\n" +
        "  $x = New-Object Xml.XmlDocument\n" +
        "  $x.PreserveWhitespace = $true\n" +
        "  $s = $mp.GetStream([IO.FileMode]::Open, [IO.FileAccess]::Read); try {{ $x.Load($s) }} finally {{ $s.Dispose() }}\n" +
        "  foreach ($node in @($x.SelectNodes('//*[@Location or @Path]'))) {{\n" +
        "    $loc = $node.GetAttribute('Location')\n" +
        "    if ($loc -and ($want -icontains (Norm $loc))) {{ $node.RemoveAttribute('Location') }}\n" +
        "    $p = $node.GetAttribute('Path')\n" +
        "    if ($p -and $node.LocalName -eq 'Asset' -and ($want -icontains (Norm $p))) {{ $null = $node.ParentNode.RemoveChild($node) }}\n" +
        "  }}\n" +
        "  $s = $mp.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); try {{ $x.Save($s) }} finally {{ $s.Dispose() }}\n" +
        "  $ju = PartUri 'manifest.json'\n" +
        "  if ($pkg.PartExists($ju)) {{\n" +
        "    $jp = $pkg.GetPart($ju)\n" +
        "    $s = $jp.GetStream([IO.FileMode]::Open, [IO.FileAccess]::Read); $r = New-Object IO.StreamReader($s); try {{ $j = $r.ReadToEnd() | ConvertFrom-Json }} finally {{ $r.Dispose() }}\n" +
        "    $sha = [Security.Cryptography.SHA256]::Create()\n" +
        "    $files = @()\n" +
        "    foreach ($f in @($j.files)) {{\n" +
        "      $u = PartUri ([string]$f.fileName)\n" +
        "      if (-not $pkg.PartExists($u)) {{ continue }}\n" +
        "      if ($f.sha256) {{\n" +
        "        $ps = $pkg.GetPart($u).GetStream([IO.FileMode]::Open, [IO.FileAccess]::Read)\n" +
        "        try {{ $h = -join ($sha.ComputeHash($ps) | ForEach-Object {{ $_.ToString('X2') }}) }} finally {{ $ps.Dispose() }}\n" +
        "        if ([string]$f.sha256 -cmatch '[a-f]') {{ $h = $h.ToLowerInvariant() }}\n" +
        "        $f.sha256 = $h\n" +
        "      }}\n" +
        "      $files += $f\n" +
        "    }}\n" +
        "    $j.files = [object[]]$files\n" +
        "    $text = ConvertTo-Json -Compress -Depth 32 -InputObject $j\n" +
        "    $s = $jp.GetStream([IO.FileMode]::Create, [IO.FileAccess]::Write); $w = New-Object IO.StreamWriter($s, (New-Object Text.UTF8Encoding $false)); try {{ $w.Write($text) }} finally {{ $w.Dispose() }}\n" +
        "  }}\n" +
        "}} finally {{ $pkg.Close() }}\n"
    let out = common::run_ps(script, #{
        "CW_SRC": Value::String(src),
        "CW_DST": Value::String(dst),
        "CW_PARTS": Value::String(wanted.join("\n"))
    }, 600)?
    if !out.success { return Err(common::failure("removing " + wanted.join(", ") + " from " + src, out)) }
    Ok(dst)
}
