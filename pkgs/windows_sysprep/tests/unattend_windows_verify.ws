use value
use fs
use shell

// PowerShell parses the file as XML (so a malformed file fails here), decodes
// each hidden password, and reads the DACL back by SID.
fn verify(facts: Value) -> Result[bool, string] {
    let script = "$ErrorActionPreference = 'Stop'\n" +
        "$p = 'C:\\Windows\\System32\\Sysprep\\unattend.xml'\n" +
        "[xml]$x = Get-Content -LiteralPath $p -Raw\n" +
        "$ns = @{{ u = 'urn:schemas-microsoft-com:unattend' }}\n" +
        "$c = Select-Xml -Xml $x -XPath '//u:component[@name=\"Microsoft-Windows-Shell-Setup\"]' -Namespace $ns\n" +
        "if (-not $c) {{ throw 'no Shell-Setup component' }}\n" +
        "$c = $c.Node\n" +
        "if ($c.processorArchitecture -ne 'amd64') {{ throw ('processorArchitecture ' + $c.processorArchitecture) }}\n" +
        "$admin = $c.UserAccounts.AdministratorPassword\n" +
        "if ($admin.PlainText -ne 'false') {{ throw 'AdministratorPassword PlainText is not false' }}\n" +
        "$dec = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($admin.Value))\n" +
        "if ($dec -ne 'Adm1n!pwAdministratorPassword') {{ throw ('AdministratorPassword decodes to ' + $dec) }}\n" +
        "$al = $c.AutoLogon.Password\n" +
        "if ($al.PlainText -ne 'false') {{ throw 'AutoLogon PlainText is not false' }}\n" +
        "$dec = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($al.Value))\n" +
        "if ($dec -ne 'Adm1n!pwPassword') {{ throw ('AutoLogon password decodes to ' + $dec) }}\n" +
        "if ($c.TimeZone -ne 'UTC') {{ throw ('TimeZone ' + $c.TimeZone) }}\n" +
        "$a = Get-Acl -LiteralPath $p\n" +
        "if (-not $a.AreAccessRulesProtected) {{ throw 'the DACL still inherits' }}\n" +
        "$sids = @($a.Access | ForEach-Object {{ $_.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value }} | Sort-Object -Unique)\n" +
        "if (($sids -join ',') -ne 'S-1-5-18,S-1-5-32-544') {{ throw ('DACL grants ' + ($sids -join ',')) }}\n" +
        "'ok'\n"
    let out = shell::powershell(script, Value::Null)?
    if !out.success || out.stdout.trim() != "ok" {
        return Err("answer file check failed (exit " + str(out.code) + "): " + out.stderr.trim() + out.stdout.trim())
    }
    if fs::exists("C:\\cw-sysprep\\old.xml") { return Err("old.xml still exists after ensure = :absent") }
    Ok(true)
}
