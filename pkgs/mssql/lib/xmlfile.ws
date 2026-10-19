use value
use common

// Reads and edits values in an XML configuration file on Windows (msmdsrv.ini
// for Analysis Services), keeping the rest of the file byte for byte: the
// document is loaded with PreserveWhitespace, so indentation, line endings
// and comments survive, and it is saved back in the encoding it was read in,
// with or without a BOM as it had. xml::to_string would reformat the whole
// file, so the edit runs in PowerShell's System.Xml instead.
//
// Paths are simple element paths, /Root/Child/Leaf: every segment is an
// element name, checked by check_xpath, so nothing user-supplied is ever
// evaluated as a general XPath expression.

fn check_xpath(xp: string) -> Result[unit, string] {
    if !xp.starts_with("/") || xp.len() < 2 { return Err("invalid element path '" + xp + "' (expected /Root/Child)") }
    for seg in xp.slice(1, xp.len()).split("/") {
        let first = seg.slice(0, 1)
        let bad_start = first == "" || "0123456789-.".contains(first)
        if bad_start || !common::only_chars(seg, "_-.") {
            return Err("invalid element name '" + seg + "' in '" + xp + "' (letters, digits, _, - and ., not starting with a digit, - or .)")
        }
    }
    Ok(())
}

fn ps_list(items: List[string]) -> string {
    "@(" + items.map(|x| common::ps_q(x)).join(", ") + ")"
}

// PowerShell that loads $path into $doc and sets $enc to its encoding.
fn load_ps(file: string) -> string {
    "$path = " + common::ps_q(file) + "\n" +
        "if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {{ throw ('XML file not found: ' + $path) }}\n" +
        "$bytes = [IO.File]::ReadAllBytes($path)\n" +
        "if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {{ $enc = New-Object Text.UnicodeEncoding($false, $true) }}\n" +
        "elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {{ $enc = New-Object Text.UnicodeEncoding($true, $true) }}\n" +
        "elseif ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {{ $enc = New-Object Text.UTF8Encoding($true) }}\n" +
        "else {{ $enc = New-Object Text.UTF8Encoding($false) }}\n" +
        "$doc = New-Object System.Xml.XmlDocument\n" +
        "$doc.PreserveWhitespace = $true\n" +
        "$doc.Load($path)\n" +
        "function Get-CwNode($xp) {{\n" +
        "  $n = $doc.SelectNodes($xp)\n" +
        "  if ($n.Count -gt 1) {{ throw ($xp + ' matches ' + $n.Count + ' elements in ' + $path) }}\n" +
        "  if ($n.Count -eq 1) {{ return ,$n[0] }}\n" +
        "  return $null\n" +
        "}}\n"
}

// The text of each element path, None where the element does not exist.
fn read_values(file: string, xpaths: List[string]) -> Result[Map[string, Option[string]], string] {
    for xp in xpaths { check_xpath(xp)? }
    let script = load_ps(file) +
        "$out = @{{}}\n" +
        "foreach ($xp in " + ps_list(xpaths) + ") {{ $n = Get-CwNode $xp; if ($null -ne $n) {{ $out[$xp] = $n.InnerText }} else {{ $out[$xp] = $null }} }}\n" +
        "$out | ConvertTo-Json -Compress"
    let v = common::ps_json("reading " + file, script, #{})?
    let res: Map[string, Option[string]] = #{}
    for xp in xpaths {
        let got = if let Some(x) = v.get(xp) { x.as_string() } else { None }
        res.insert(xp, got)
    }
    Ok(res)
}

// Sets each [element path, text] pair, creating missing elements on the path
// (indented like their siblings). Writes the file only when a value changed:
// to a temp file beside it, then [IO.File]::Replace, which keeps the
// original's ACL. Returns whether the file changed.
fn write_values(file: string, pairs: List[List[string]]) -> Result[bool, string] {
    for p in pairs { check_xpath(p[0])? }
    let xps = pairs.map(|p| p[0])
    let vals = pairs.map(|p| p[1])
    let script = load_ps(file) +
        "$xps = " + ps_list(xps) + "\n" +
        "$vals = " + ps_list(vals) + "\n" +
        "$changed = $false\n" +
        "for ($i = 0; $i -lt $xps.Count; $i++) {{\n" +
        "  $n = Get-CwNode $xps[$i]\n" +
        "  if ($null -eq $n) {{\n" +
        "    $segs = $xps[$i].TrimStart('/').Split('/')\n" +
        "    $cur = $doc.DocumentElement\n" +
        "    if ($cur.Name -ne $segs[0]) {{ throw ('the root element of ' + $path + ' is ' + $cur.Name + ', not ' + $segs[0]) }}\n" +
        "    for ($j = 1; $j -lt $segs.Count; $j++) {{\n" +
        "      $next = $cur.SelectSingleNode($segs[$j])\n" +
        "      if ($null -eq $next) {{\n" +
        "        $next = $doc.CreateElement($segs[$j], $cur.NamespaceURI)\n" +
        // Indent like the existing children, or one step deeper than the parent.
        "        $first = $cur.SelectSingleNode('*')\n" +
        "        $ws = $null\n" +
        "        if ($null -ne $first -and $null -ne $first.PreviousSibling -and $first.PreviousSibling.NodeType -eq 'Whitespace') {{ $ws = $first.PreviousSibling.Value }}\n" +
        "        elseif ($null -ne $cur.PreviousSibling -and $cur.PreviousSibling.NodeType -eq 'Whitespace') {{ $ws = $cur.PreviousSibling.Value + \"`t\" }}\n" +
        "        $last = $cur.LastChild\n" +
        "        if ($null -ne $last -and $last.NodeType -eq 'Whitespace' -and $null -ne $first) {{\n" +
        "          [void]$cur.InsertBefore($next, $last)\n" +
        "          if ($ws) {{ [void]$cur.InsertBefore($doc.CreateWhitespace($ws), $next) }}\n" +
        "        }} else {{\n" +
        "          if ($ws) {{ [void]$cur.AppendChild($doc.CreateWhitespace($ws)) }}\n" +
        "          [void]$cur.AppendChild($next)\n" +
        "          if ($ws -and $null -ne $cur.PreviousSibling -and $cur.PreviousSibling.NodeType -eq 'Whitespace') {{ [void]$cur.AppendChild($doc.CreateWhitespace($cur.PreviousSibling.Value)) }}\n" +
        "        }}\n" +
        "      }}\n" +
        "      $cur = $next\n" +
        "    }}\n" +
        "    $n = $cur\n" +
        "  }}\n" +
        "  if ($null -ne $n.SelectSingleNode('*')) {{ throw ($xps[$i] + ' in ' + $path + ' has child elements, so it holds no single value') }}\n" +
        "  if ($n.InnerText -cne $vals[$i]) {{ $n.InnerText = $vals[$i]; $changed = $true }}\n" +
        "}}\n" +
        "if ($changed) {{\n" +
        "  $tmp = $path + '.config-weave.tmp'\n" +
        "  $settings = New-Object System.Xml.XmlWriterSettings\n" +
        "  $settings.Encoding = $enc\n" +
        "  $settings.NewLineHandling = [System.Xml.NewLineHandling]::None\n" +
        "  $settings.OmitXmlDeclaration = -not ($doc.FirstChild -is [System.Xml.XmlDeclaration])\n" +
        "  try {{\n" +
        "    $w = [System.Xml.XmlWriter]::Create($tmp, $settings)\n" +
        "    try {{ $doc.Save($w) }} finally {{ $w.Close() }}\n" +
        // A $null backup path reaches .NET as "", which Replace rejects.
        "    [IO.File]::Replace($tmp, $path, [NullString]::Value)\n" +
        "  }} finally {{ if (Test-Path -LiteralPath $tmp) {{ Remove-Item -LiteralPath $tmp -Force }} }}\n" +
        "  'changed'\n" +
        "}}"
    let out = common::ps("writing " + file, script)?
    Ok(out == "changed")
}
