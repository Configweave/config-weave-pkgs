use value
use shell

// Compares each seeded msmdsrv.ini with what it must hold after the steps,
// byte for byte: the encoding preamble, the line endings, the comment, the
// self-closing element and the indentation of the created elements.
fn verify(facts: Value) -> Result[bool, string] {
    let script = "$ErrorActionPreference = 'Stop'\n" +
        "$t = [string][char]9\n" +
        "function Doc($nl, $process, $query, $enabled) {{\n" +
        "  $q = if ($query) {{ $t + $t + '<Query>' + $nl + $t + $t + $t + '<MaxThreads>' + $query + '</MaxThreads>' + $nl + $t + $t + '</Query>' + $nl }} else {{ '' }}\n" +
        "  '<ConfigurationSettings>' + $nl + $t + '<!-- seeded by the mssql test -->' + $nl +\n" +
        "  $t + '<ThreadPool>' + $nl + $t + $t + '<Process>' + $nl + $t + $t + $t + '<MaxThreads>' + $process + '</MaxThreads>' + $nl + $t + $t + '</Process>' + $nl + $q + $t + '</ThreadPool>' + $nl +\n" +
        "  $t + '<AllowedBrowsingFolders />' + $nl + $t + '<Log>' + $nl + $t + $t + '<FlightRecorder>' + $nl + $t + $t + $t + '<Enabled>' + $enabled + '</Enabled>' + $nl + $t + $t + '</FlightRecorder>' + $nl + $t + '</Log>' + $nl +\n" +
        "  '</ConfigurationSettings>' + $nl\n" +
        "}}\n" +
        "$bad = @()\n" +
        "$crlf = [string][char]13 + [char]10\n" +
        "$checks = @(\n" +
        "  @('C:\\cw-as\\CWBOM\\OLAP\\Config\\msmdsrv.ini', ([byte[]](0xEF, 0xBB, 0xBF) + [Text.Encoding]::UTF8.GetBytes((Doc $crlf '512' '32' '1')))),\n" +
        "  @('C:\\cw-as\\CWLF\\OLAP\\Config\\msmdsrv.ini', ([Text.Encoding]::UTF8.GetBytes((Doc ([string][char]10) '0' '' '0'))))\n" +
        ")\n" +
        "foreach ($c in $checks) {{\n" +
        "  $have = [IO.File]::ReadAllBytes($c[0])\n" +
        "  if ([Convert]::ToBase64String($have) -ne [Convert]::ToBase64String([byte[]]$c[1])) {{\n" +
        "    $bad += ($c[0] + ' holds: ' + ([Text.Encoding]::UTF8.GetString($have) -replace [string][char]13, '\\r' -replace [string][char]10, '\\n' -replace [string][char]9, '\\t') + ' (' + $have.Length + ' bytes, first ' + $have[0] + ')')\n" +
        "  }}\n" +
        "}}\n" +
        "if (Get-ChildItem C:\\cw-as -Recurse -Filter '*.tmp') {{ $bad += 'a temp file was left behind' }}\n" +
        "if ($bad) {{ [Console]::Error.WriteLine($bad -join '; '); exit 1 }}\n"
    let out = shell::powershell(script, Value::Null)?
    if !out.success { return Err(out.stderr.trim() + " " + out.stdout.trim()) }
    Ok(true)
}
