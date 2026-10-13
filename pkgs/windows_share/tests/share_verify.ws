use value
use common

// Reads every share back and fails with the list of what is wrong: path,
// description, settings and the exact access list, by SID.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::run_ps(
        "$bad = New-Object System.Collections.Generic.List[string]\n" +
        "function Sid([string]$n) {{ try {{ ([System.Security.Principal.NTAccount]$n).Translate([System.Security.Principal.SecurityIdentifier]).Value }} catch {{ $n }} }}\n" +
        "function Access($name) {{ (@(Get-SmbShareAccess -Name $name | ForEach-Object {{ (Sid $_.AccountName) + '/' + $_.AccessControlType + '/' + $_.AccessRight }}) | Sort-Object) -join ',' }}\n" +
        "$d = Get-SmbShare -Name weave-data -ErrorAction SilentlyContinue\n" +
        "if ($null -eq $d) {{ $bad.Add('weave-data is missing') }} else {{\n" +
        "  if ($d.Path -ne 'C:\\weave-share-test' -or $d.Description -ne 'config-weave test share') {{ $bad.Add('weave-data is ' + $d.Path + ' / ' + $d.Description) }}\n" +
        "  if (-not $d.EncryptData -or [string]$d.CachingMode -ne 'None' -or [string]$d.FolderEnumerationMode -ne 'AccessBased' -or $d.ConcurrentUserLimit -ne 5) {{ $bad.Add('weave-data settings: ' + $d.EncryptData + ' ' + $d.CachingMode + ' ' + $d.FolderEnumerationMode + ' ' + $d.ConcurrentUserLimit) }}\n" +
        "  $a = Access 'weave-data'\n" +
        "  if ($a -ne 'S-1-1-0/Allow/Read,S-1-5-32-544/Allow/Full,S-1-5-32-545/Allow/Change') {{ $bad.Add('weave-data access: ' + $a) }}\n" +
        "}}\n" +
        "$d = Get-SmbShare -Name weave-drift -ErrorAction SilentlyContinue\n" +
        "if ($null -eq $d -or $d.Description -ne 'new description') {{ $bad.Add('weave-drift description was not updated') }}\n" +
        "$a = Access 'weave-drift'\n" +
        "if ($a -ne 'S-1-5-11/Allow/Read,S-1-5-32-544/Allow/Full') {{ $bad.Add('weave-drift access: ' + $a) }}\n" +
        "$d = Get-SmbShare -Name weave-moved -ErrorAction SilentlyContinue\n" +
        "if ($null -eq $d -or $d.Path -ne 'C:\\weave-share-new') {{ $bad.Add('weave-moved was not moved') }}\n" +
        "if ($null -ne (Get-SmbShare -Name weave-gone -ErrorAction SilentlyContinue)) {{ $bad.Add('weave-gone still exists') }}\n" +
        "if (-not (Test-Path -LiteralPath 'C:\\weave-share-gone')) {{ $bad.Add('removing weave-gone deleted its directory') }}\n" +
        "$d = Get-SmbShare -Name weave-keep -ErrorAction SilentlyContinue\n" +
        "if ($null -eq $d -or $d.Path -ne 'C:\\weave-share-keep' -or $d.Description -ne 'kept') {{ $bad.Add('weave-keep was changed by a failing step') }}\n" +
        "if ($null -eq (Get-SmbShare -Name 'ADMIN$' -ErrorAction SilentlyContinue)) {{ $bad.Add('ADMIN$ is gone') }}\n" +
        "$bad -join '; '\n"
    )?
    if !out.success { return Err(common::failure("verify", out)) }
    let problems = out.stdout.trim()
    if problems != "" { return Err(problems) }
    Ok(true)
}
