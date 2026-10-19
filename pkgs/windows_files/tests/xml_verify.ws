use value
use common

// Every fixture byte for byte (BOM, encoding, line endings and comments
// included), the pending-restart marker gone, and Spooler restarted after
// the fixtures were written.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::run_ps(
        "$bad = New-Object System.Collections.Generic.List[string]\n" +
        "$crlf = [char]13 + [char]10\n" +
        "function Bytes($p, [byte[]]$want, $what) {{\n" +
        "  $have = [IO.File]::ReadAllBytes($p)\n" +
        "  if ([Convert]::ToBase64String($have) -ne [Convert]::ToBase64String($want)) {{ $bad.Add($p + ' (' + $what + ') holds: ' + [Text.Encoding]::UTF8.GetString($have).Replace([string][char]13, '\\r').Replace([string][char]10, '\\n')) }}\n" +
        "}}\n" +
        "$bom = New-Object Text.UTF8Encoding $true\n" +
        "$nobom = New-Object Text.UTF8Encoding $false\n" +
        "$ini = '<?xml version=\"1.0\" encoding=\"UTF-8\"?>' + $crlf + '<!-- keep me -->' + $crlf + '<ConfigurationSettings>' + $crlf + '  <ThreadPool>' + $crlf + '    <Process>' + $crlf + '      <MaxThreads>512</MaxThreads>' + $crlf + '      <MinThreads>8</MinThreads>' + $crlf + '    </Process>' + $crlf + '  </ThreadPool>' + $crlf + '  <Log Level=\"debug\" />' + $crlf + '</ConfigurationSettings>' + $crlf\n" +
        "Bytes 'C:\\weave-xml\\ini.xml' ($bom.GetPreamble() + $bom.GetBytes($ini)) 'UTF-8 with BOM, CRLF'\n" +
        "Bytes 'C:\\weave-xml\\lf.xml' ($nobom.GetBytes(\"<config>`n  <a>2</a>`n</config>`n\")) 'UTF-8, LF, no declaration'\n" +
        "$u = New-Object Text.UnicodeEncoding $false, $true\n" +
        "Bytes 'C:\\weave-xml\\utf16.xml' ($u.GetPreamble() + $u.GetBytes('<?xml version=\"1.0\" encoding=\"utf-16\"?>' + $crlf + '<config><name>new</name></config>')) 'UTF-16'\n" +
        "Bytes 'C:\\weave-xml\\ns.xml' ($nobom.GetBytes('<root xmlns=\"urn:cw\"><item k=\"z\">1</item><item k=\"z\">2</item></root>')) 'namespaced'\n" +
        "Bytes 'C:\\weave-xml\\remove.xml' ($nobom.GetBytes('<config>' + $crlf + '</config>' + $crlf)) 'element removed with its indentation'\n" +
        "Bytes 'C:\\weave-xml\\ready.xml' ($nobom.GetBytes('<config><mode>on</mode></config>')) 'untouched'\n" +
        "if (@(Get-ChildItem -LiteralPath 'C:\\weave-xml' -Filter '*.config-weave-tmp').Count -gt 0) {{ $bad.Add('a temp file was left behind') }}\n" +
        "if (@(Get-ChildItem -LiteralPath 'C:\\ProgramData\\config-weave\\xml_value-restart' -File -ErrorAction SilentlyContinue).Count -gt 0) {{ $bad.Add('a pending-restart marker was left behind') }}\n" +
        "$spool = Get-Process -Name spoolsv -ErrorAction SilentlyContinue\n" +
        "if (-not $spool) {{ $bad.Add('Spooler is not running') }}\n" +
        "elseif ($spool.StartTime -lt (Get-Item -LiteralPath 'C:\\weave-xml\\ready.xml').LastWriteTime) {{ $bad.Add('Spooler was not restarted after the fixtures were written') }}\n" +
        "$bad -join '; '\n"
    )?
    if !out.success { return Err(common::failure("verify", out)) }
    let problems = out.stdout.trim()
    if problems != "" { return Err(problems) }
    Ok(true)
}
