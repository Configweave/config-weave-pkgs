use value
use common

// Reads everything back through .NET and fails with the list of what is
// wrong: kinds as well as data, the 32-bit view, removals, and the keys'
// owner and explicit rules by SID and mask.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::run_ps(
        "$bad = New-Object System.Collections.Generic.List[string]\n" +
        "$hk = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry64')\n" +
        "$k = $hk.OpenSubKey('SOFTWARE\\ConfigWeaveTest')\n" +
        "function Want($name, $kind, $data) {{\n" +
        "  if (-not (@($k.GetValueNames()) -contains $name)) {{ $bad.Add($name + ' is missing'); return }}\n" +
        "  $hk2 = $k.GetValueKind($name).ToString()\n" +
        "  if ($hk2 -ne $kind) {{ $bad.Add($name + ' is ' + $hk2 + ', wanted ' + $kind) }}\n" +
        "  $v = $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames')\n" +
        "  if ($v -is [array]) {{ $v = ($v | ForEach-Object {{ [string]$_ }}) -join '|' }}\n" +
        "  if ([string]$v -ne $data) {{ $bad.Add($name + ' holds ' + [string]$v + ', wanted ' + $data) }}\n" +
        "}}\n" +
        "Want 'greeting' 'String' 'hello from config-weave'\n" +
        "Want '' 'String' 'the default'\n" +
        "Want 'answer' 'DWord' '42'\n" +
        "Want 'all_bits' 'DWord' '-1'\n" +
        "Want 'big' 'QWord' '-1'\n" +
        "Want 'expand' 'ExpandString' '%SystemRoot%\\cw'\n" +
        "Want 'kindchange' 'ExpandString' 'plain-text'\n" +
        "Want 'multi' 'MultiString' 'one|two words'\n" +
        "Want 'multi_single' 'MultiString' 'solo'\n" +
        "Want 'bin_hex' 'Binary' '222|173|190|239'\n" +
        "Want 'bin_bytes' 'Binary' '0|16|255'\n" +
        "Want 'blob2' 'String' 'now a string'\n" +
        "foreach ($n in 'blob', 'gone', 'never-written', 'too_big') {{ if (@($k.GetValueNames()) -contains $n) {{ $bad.Add($n + ' should not exist') }} }}\n" +
        "$k32 = [Microsoft.Win32.RegistryKey]::OpenBaseKey('LocalMachine', 'Registry32').OpenSubKey('SOFTWARE\\ConfigWeaveTest32')\n" +
        "if ($null -eq $k32 -or $k32.GetValue('bits') -ne '32') {{ $bad.Add('the 32-bit view value is missing') }}\n" +
        "if ($null -ne $hk.OpenSubKey('SOFTWARE\\ConfigWeaveTest32')) {{ $bad.Add('the 32-bit view value landed in the 64-bit view') }}\n" +
        "if ($null -eq $hk.OpenSubKey('SOFTWARE\\ConfigWeaveTest\\Sub')) {{ $bad.Add('Sub key is missing') }}\n" +
        "if ($null -ne $hk.OpenSubKey('SOFTWARE\\ConfigWeaveTest\\Doomed')) {{ $bad.Add('Doomed key still exists') }}\n" +
        "if ($null -eq $hk.OpenSubKey('SOFTWARE\\Microsoft')) {{ $bad.Add('SOFTWARE\\Microsoft is gone') }}\n" +
        "$sid = [System.Security.Principal.SecurityIdentifier]\n" +
        "$acl = $hk.OpenSubKey('SOFTWARE\\ConfigWeaveTest\\Acl').GetAccessControl()\n" +
        "if ($acl.GetOwner($sid).Value -ne 'S-1-5-32-551') {{ $bad.Add('Acl owner is ' + $acl.GetOwner($sid).Value) }}\n" +
        "$want = [int64]([int][System.Security.AccessControl.RegistryRights]'ReadKey, WriteKey')\n" +
        "$users = [int64]0\n" +
        "foreach ($r in $acl.GetAccessRules($true, $false, $sid)) {{ if ($r.IdentityReference.Value -eq 'S-1-5-32-545' -and [string]$r.AccessControlType -eq 'Allow') {{ $users = $users -bor [int64]([int]$r.RegistryRights) }} }}\n" +
        "if (($users -band $want) -ne $want) {{ $bad.Add('Users holds ' + $users + ' on Acl, wanted ' + $want) }}\n" +
        "$ex = @($hk.OpenSubKey('SOFTWARE\\ConfigWeaveTest\\Exact').GetAccessControl().GetAccessRules($true, $false, $sid))\n" +
        "if ($ex.Count -ne 1 -or $ex[0].IdentityReference.Value -ne 'S-1-5-32-545' -or [int]$ex[0].RegistryRights -ne [int][System.Security.AccessControl.RegistryRights]::ReadKey) {{ $bad.Add('Exact explicit rules: ' + (($ex | ForEach-Object {{ $_.IdentityReference.Value + '=' + [int]$_.RegistryRights }}) -join ', ')) }}\n" +
        "$bad -join '; '\n"
    )?
    if !out.success { return Err(common::failure("verify", out)) }
    let problems = out.stdout.trim()
    if problems != "" { return Err(problems) }
    Ok(true)
}
