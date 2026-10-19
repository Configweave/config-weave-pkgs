use value
use fs
use path
use env
use hash
use regex
use service
use log
use common

// Sets (or removes) one value in an XML file through .NET's XmlDocument
// with PreserveWhitespace, so indentation, line endings, comments and the
// BOM stay as they were; the file is written to a temp file beside it and
// swapped in with ReplaceFile, keeping its NTFS permissions. Only a node
// this resource actually changed makes the file "changed": re-serialising
// alone never counts, because XmlDocument normalises a few spellings
// (`<a/>` becomes `<a />`, single-quoted attributes become double-quoted)
// that are not drift.

fn ps_bool(b: bool) -> string { if b { "$true" } else { "$false" } }

fn opts(params: Value) -> Result[string, string] {
    let p = common::param_str(params, "path", "")
    common::require_path("path", p)?
    let xpath = common::param_str(params, "xpath", "")
    if xpath.trim() == "" { return Err("missing 'xpath' parameter") }
    let attr = common::param_str(params, "attribute", "")
    if attr != "" && !regex::is_match("^[A-Za-z_][A-Za-z0-9_.-]*$", attr) {
        return Err("invalid 'attribute' '" + attr + "' (expected a local attribute name without a prefix)")
    }
    let present = common::want_present(params)?
    let ns = "@{{ "
    if let Some(v) = params.get("namespaces") {
        if let Some(m) = v.as_map() {
            for k in m.keys() {
                if !regex::is_match("^[A-Za-z_][A-Za-z0-9_.-]*$", k) { return Err("invalid namespace prefix '" + k + "'") }
                let uri = m.get(k).unwrap_or(Value::Null).as_string().unwrap_or("")
                if uri == "" { return Err("namespace prefix '" + k + "' needs a non-empty URI string") }
                ns = ns + common::ps_q(k) + " = " + common::ps_q(uri) + "; "
            }
        }
    }
    ns = ns + "}}"
    Ok("$path = " + common::ps_q(p) + "\n" +
        "$xpath = " + common::ps_q(xpath) + "\n" +
        "$value = " + common::ps_q(common::param_str(params, "value", "")) + "\n" +
        "$attr = " + common::ps_q(attr) + "\n" +
        "$present = " + ps_bool(present) + "\n" +
        "$create = " + ps_bool(common::param_bool(params, "create", false)) + "\n" +
        "$all = " + ps_bool(common::param_bool(params, "all", false)) + "\n" +
        "$ns = " + ns + "\n")
}

// The XML work. Prints "same", "changed", or "missing" when the file to
// change does not exist yet (drift for check, an error for apply); with
// $write it also writes the change.
fn body() -> string {
    "$enc = $null\n" +
    "if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {{\n" +
    "  if (-not $present) {{ 'same'; exit 0 }}\n" +
    "  if ($write) {{ throw ('''' + $path + ''' does not exist') }}\n" +
    "  'missing'; exit 0\n" +
    "}}\n" +
    "$bytes = [IO.File]::ReadAllBytes($path)\n" +
    "$bom = 0\n" +
    "if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {{ $enc = New-Object Text.UTF8Encoding $true; $bom = 3 }}\n" +
    "elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {{ $enc = New-Object Text.UnicodeEncoding $false, $true; $bom = 2 }}\n" +
    "elseif ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {{ $enc = New-Object Text.UnicodeEncoding $true, $true; $bom = 2 }}\n" +
    "$doc = New-Object Xml.XmlDocument\n" +
    "$doc.PreserveWhitespace = $true\n" +
    "$doc.XmlResolver = $null\n" +
    "try {{ $doc.Load((New-Object IO.MemoryStream (,$bytes))) }} catch {{ throw ('''' + $path + ''' is not well-formed XML: ' + $_.Exception.Message) }}\n" +
    "$decl = $doc.FirstChild -as [Xml.XmlDeclaration]\n" +
    "if ($null -eq $enc) {{\n" +
    "  $name = if ($decl) {{ [string]$decl.Encoding }} else {{ '' }}\n" +
    "  if ($name -eq '' -or $name -match '^utf-?8$') {{ $enc = New-Object Text.UTF8Encoding $false }}\n" +
    "  else {{ $enc = [Text.Encoding]::GetEncoding($name) }}\n" +
    "}}\n" +
    "$nsm = New-Object Xml.XmlNamespaceManager $doc.NameTable\n" +
    "foreach ($k in $ns.Keys) {{ $nsm.AddNamespace($k, $ns[$k]) }}\n" +
    "try {{ $nodes = @($doc.SelectNodes($xpath, $nsm)) }} catch {{ throw ('invalid xpath ''' + $xpath + ''': ' + $_.Exception.Message) }}\n" +
    "if ($nodes.Count -gt 1 -and -not $all) {{ throw ('xpath ''' + $xpath + ''' matches ' + $nodes.Count + ' nodes; set all = true to change every one') }}\n" +
    "$dirty = $false\n" +
    // Indents a new child like its last element sibling, when it has one.
    "function Add-Child($parent, $child) {{\n" +
    "  $last = $parent.LastChild\n" +
    "  $prev = $null\n" +
    "  foreach ($c in $parent.ChildNodes) {{ if ($c -is [Xml.XmlElement] -and $c.PreviousSibling -is [Xml.XmlWhitespace]) {{ $prev = $c.PreviousSibling }} }}\n" +
    "  if ($prev -and $last -is [Xml.XmlWhitespace]) {{\n" +
    "    [void]$parent.InsertBefore($doc.CreateWhitespace($prev.Value), $last)\n" +
    "    [void]$parent.InsertBefore($child, $last)\n" +
    "  }} else {{ [void]$parent.AppendChild($child) }}\n" +
    "}}\n" +
    // create = true: walk a plain /a/b/c (or /a/b/@c) path, adding what is missing.
    "function New-Path {{\n" +
    "  if (-not $xpath.StartsWith('/') -or $xpath.StartsWith('//')) {{ throw ('create needs an absolute path of plain element names such as /a/b/c, got ''' + $xpath + '''') }}\n" +
    "  $steps = $xpath.Substring(1).Split('/')\n" +
    "  $node = $doc\n" +
    "  for ($i = 0; $i -lt $steps.Count; $i++) {{\n" +
    "    $s = $steps[$i]\n" +
    "    if ($s.StartsWith('@') -and $i -eq $steps.Count - 1 -and $s -match '^@[A-Za-z_][A-Za-z0-9_.-]*$') {{\n" +
    "      if ($attr -ne '') {{ throw 'set either attribute or an @name xpath step, not both' }}\n" +
    "      $node.SetAttribute($s.Substring(1), $value)\n" +
    "      return $node.GetAttributeNode($s.Substring(1))\n" +
    "    }}\n" +
    "    if ($s -notmatch '^([A-Za-z_][A-Za-z0-9_.-]*:)?[A-Za-z_][A-Za-z0-9_.-]*$') {{ throw ('create needs an absolute path of plain element names such as /a/b/c; cannot create step ''' + $s + '''') }}\n" +
    "    $next = $node.SelectSingleNode($s, $nsm)\n" +
    "    if ($null -eq $next) {{\n" +
    "      if ($node -eq $doc -and $doc.DocumentElement) {{ throw ('the document element is ' + $doc.DocumentElement.Name + ', not ' + $s) }}\n" +
    "      $parts = $s.Split(':')\n" +
    "      if ($parts.Count -eq 2) {{\n" +
    "        if (-not $ns.ContainsKey($parts[0])) {{ throw ('prefix ''' + $parts[0] + ''' is not in namespaces') }}\n" +
    "        $next = $doc.CreateElement($parts[0], $parts[1], $ns[$parts[0]])\n" +
    "      }} else {{ $next = $doc.CreateElement($s, $node.NamespaceURI) }}\n" +
    "      if ($node -eq $doc) {{ [void]$doc.AppendChild($next) }} else {{ Add-Child $node $next }}\n" +
    "    }}\n" +
    "    $node = $next\n" +
    "  }}\n" +
    "  $node\n" +
    "}}\n" +
    "if ($present) {{\n" +
    "  if ($nodes.Count -eq 0) {{\n" +
    "    if (-not $create) {{ throw ('xpath ''' + $xpath + ''' matches nothing in ''' + $path + '''; set create = true to add the missing elements') }}\n" +
    "    $nodes = @(New-Path)\n" +
    "    $dirty = $true\n" +
    "  }}\n" +
    "  foreach ($n in $nodes) {{\n" +
    "    if ($attr -ne '') {{\n" +
    "      if ($n -isnot [Xml.XmlElement]) {{ throw ('attribute needs an xpath that selects elements; ''' + $xpath + ''' selects a ' + $n.NodeType + ' node') }}\n" +
    "      if (-not $n.HasAttribute($attr) -or $n.GetAttribute($attr) -cne $value) {{ $n.SetAttribute($attr, $value); $dirty = $true }}\n" +
    "    }} elseif ($n -is [Xml.XmlAttribute]) {{\n" +
    "      if ($n.Value -cne $value) {{ $n.Value = $value; $dirty = $true }}\n" +
    "    }} elseif ($n -is [Xml.XmlElement]) {{\n" +
    "      if ($n.SelectNodes('*').Count -gt 0) {{ throw ('''' + $xpath + ''' selects ' + $n.Name + ', which has child elements; xml_value sets the text of a leaf element') }}\n" +
    "      if ($n.InnerText -cne $value) {{ $n.InnerText = $value; $dirty = $true }}\n" +
    "    }} else {{ throw ('xpath ''' + $xpath + ''' selects a ' + $n.NodeType + ' node; select an element or an attribute') }}\n" +
    "  }}\n" +
    "}} else {{\n" +
    "  foreach ($n in $nodes) {{\n" +
    "    if ($attr -ne '') {{\n" +
    "      if ($n -is [Xml.XmlElement] -and $n.HasAttribute($attr)) {{ $n.RemoveAttribute($attr); $dirty = $true }}\n" +
    "    }} elseif ($n -is [Xml.XmlAttribute]) {{\n" +
    "      [void]$n.OwnerElement.RemoveAttributeNode($n); $dirty = $true\n" +
    "    }} elseif ($n -is [Xml.XmlElement] -and $n -ne $doc.DocumentElement) {{\n" +
    "      $parent = $n.ParentNode\n" +
    "      if ($n.PreviousSibling -is [Xml.XmlWhitespace]) {{ [void]$parent.RemoveChild($n.PreviousSibling) }}\n" +
    "      [void]$parent.RemoveChild($n); $dirty = $true\n" +
    "    }} else {{ throw ('xpath ''' + $xpath + ''' selects a ' + $n.NodeType + ' node, which ensure = :absent cannot remove') }}\n" +
    "  }}\n" +
    "}}\n" +
    "if (-not $dirty) {{ 'same'; exit 0 }}\n" +
    "if (-not $write) {{ 'changed'; exit 0 }}\n" +
    // The original declaration is put back verbatim: the writer would
    // otherwise re-spell it (encoding=\"UTF-8\" becomes \"utf-8\").
    "$text = $enc.GetString($bytes, $bom, $bytes.Length - $bom)\n" +
    "$head = ''\n" +
    "if ($decl) {{\n" +
    "  $m = [regex]::Match($text, '^<\\?xml[^>]*\\?>')\n" +
    "  if ($m.Success) {{ $head = $m.Value; [void]$doc.RemoveChild($decl) }}\n" +
    "}}\n" +
    "$set = New-Object Xml.XmlWriterSettings\n" +
    "$set.OmitXmlDeclaration = $true\n" +
    "$set.NewLineHandling = [Xml.NewLineHandling]::None\n" +
    "$set.Indent = $false\n" +
    "$sw = New-Object IO.StringWriter\n" +
    "$w = [Xml.XmlWriter]::Create($sw, $set)\n" +
    "$doc.Save($w)\n" +
    "$w.Close()\n" +
    "$ms = New-Object IO.MemoryStream\n" +
    "$ms.Write($bytes, 0, $bom)\n" +
    "$b = $enc.GetBytes($head + $sw.ToString())\n" +
    "$ms.Write($b, 0, $b.Length)\n" +
    "$out = $ms.ToArray()\n" +
    "$tmp = $path + '.config-weave-tmp'\n" +
    "[IO.File]::WriteAllBytes($tmp, $out)\n" +
    "try {{ [IO.File]::Replace($tmp, $path, [NullString]::Value) }} finally {{ if (Test-Path -LiteralPath $tmp) {{ Remove-Item -LiteralPath $tmp -Force }} }}\n" +
    "'changed'\n"
}

fn run_xml(params: Value, write: bool) -> Result[bool, string] {
    let head = opts(params)?
    let w = if write { "$write = $true\n" } else { "$write = $false\n" }
    let out = common::run_ps(head + w + body())?
    if !out.success { return Err(common::failure("xml_value on " + common::param_str(params, "path", ""), out)) }
    let said = out.stdout.trim()
    Ok(said == "changed" || said == "missing")
}

// A restart that failed after the file was written would otherwise be lost:
// the next check sees the right value and never restarts the service. So a
// marker is written before the file changes and removed only once the
// service has restarted; while it exists the step is not configured.
fn pending_marker(params: Value, svc: string) -> string {
    let base = env::get("ProgramData").unwrap_or("C:\\ProgramData")
    let key = hash::sha256(common::norm_path(common::param_str(params, "path", "")) + "|" + svc.to_lower())
    path::join(path::join(base, "config-weave\\xml_value-restart"), key)
}

fn restart_svc(params: Value) -> Result[string, string] {
    let svc = common::param_str(params, "restart_service", "")
    if svc == "" { return Ok("") }
    if svc.contains("\n") || svc.contains("\r") { return Err("'restart_service' must not contain a line break") }
    // A missing service is a check-time error, not a surprise after the
    // file has been changed.
    service::status(svc)?
    Ok(svc)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let svc = restart_svc(params)?
    if run_xml(params, false)? { return Ok(CheckResult::NotConfigured) }
    if svc != "" && fs::exists(pending_marker(params, svc)) { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let svc = restart_svc(params)?
    let marker = if svc != "" { pending_marker(params, svc) } else { "" }
    if svc != "" && run_xml(params, false)? {
        fs::mkdir(path::parent(marker))?
        fs::write(marker, common::param_str(params, "path", ""))?
    }
    if run_xml(params, true)? {
        log::info("changed " + common::param_str(params, "xpath", "") + " in " + common::param_str(params, "path", ""))
    }
    if svc != "" && fs::exists(marker) {
        // A stopped service picks the change up when it next starts.
        if service::status(svc)? != "stopped" {
            log::info("restarting " + svc)
            service::restart(svc, Value::Map(#{ "timeout": Value::Int(180), "stop_dependents": Value::Bool(true) }))?
        }
        fs::delete(marker)?
    }
    Ok(ApplyResult::Success)
}
