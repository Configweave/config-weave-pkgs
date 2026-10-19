use value
use common

// Reads everything back and fails with the list of what is wrong: content
// byte for byte, removals, owners and rules by SID and mask, protection,
// and links by kind and target.
fn verify(facts: Value) -> Result[bool, string] {
    let out = common::run_ps(
        "$bad = New-Object System.Collections.Generic.List[string]\n" +
        "$sid = [System.Security.Principal.SecurityIdentifier]\n" +
        "function Text($p, $want) {{\n" +
        "  if (-not (Test-Path -LiteralPath $p)) {{ $bad.Add($p + ' is missing'); return }}\n" +
        "  $have = [IO.File]::ReadAllText($p)\n" +
        "  $bytes = [IO.File]::ReadAllBytes($p)\n" +
        "  if ($have -ne $want -or ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF)) {{ $bad.Add($p + ' holds ' + $have) }}\n" +
        "}}\n" +
        "function Gone($p) {{ if (Test-Path -LiteralPath $p) {{ $bad.Add($p + ' should not exist') }} }}\n" +
        "function Rules($p) {{ @((Get-Item -LiteralPath $p -Force).GetAccessControl('Access').GetAccessRules($true, $false, $sid)) }}\n" +
        "function Mask($r) {{ [int64]([int]$r.FileSystemRights) -band 0xFFFFFFFFL }}\n" +
        "function Link($p, $type, $target) {{\n" +
        "  $i = Get-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue\n" +
        "  if ($null -eq $i) {{ $bad.Add($p + ' is missing'); return }}\n" +
        "  if ([string]$i.LinkType -ne $type -or [string](@($i.Target)[0]) -ne $target) {{ $bad.Add($p + ' is ' + $i.LinkType + ' -> ' + (@($i.Target) -join ',')) }}\n" +
        "}}\n" +
        "Text 'C:\\weave-files-test\\hello.txt' 'hello from config-weave'\n" +
        "Text 'C:\\weave-files-test\\rendered.txt' ('host=weave' + [char]13 + [char]10 + 'port=8080' + [char]13 + [char]10)\n" +
        "Text 'C:\\weave-files-seed\\drift.txt' ('new content' + [char]10)\n" +
        "Text 'C:\\weave-files-seed\\utf16.txt' 'now utf-8'\n" +
        "foreach ($p in 'C:\\weave-files-seed\\remove_me.txt', 'C:\\weave-files-seed\\tpl_remove.txt', 'C:\\weave-files-seed\\rmdir', 'C:\\weave-files-test\\ghost.txt', 'C:\\weave-files-test\\bad-digest.txt', 'C:\\weave-files-test\\empty.txt', 'C:\\weave-files-seed\\deadlink', 'C:\\weave-files-seed\\deadfile', 'C:\\weave-files-seed\\deadtpl') {{ Gone $p }}\n" +
        "if (@(Get-ChildItem -LiteralPath 'C:\\weave-files-test' -Filter '*.config-weave-download').Count -gt 0) {{ $bad.Add('a download temp file was left behind') }}\n" +
        "if (-not (Test-Path -LiteralPath 'C:\\Windows\\System32')) {{ $bad.Add('C:\\Windows is damaged') }}\n" +
        "if ((Get-FileHash -LiteralPath 'C:\\weave-files-test\\rfc2549.txt' -Algorithm SHA256).Hash -ne '646B43B5D718913D6211E2C18B2B3B667CF6EAA76A2493E55B1DE5CA04C2578E') {{ $bad.Add('rfc2549.txt has the wrong digest') }}\n" +
        // Users on the working directory: the merged mask, reaching children.
        "$want = [int64]([int][System.Security.AccessControl.FileSystemRights]'Modify, ReadAndExecute, Read, Write')\n" +
        "$users = [int64]0\n" +
        "foreach ($r in (Rules 'C:\\weave-files-test')) {{ if ($r.IdentityReference.Value -eq 'S-1-5-32-545' -and [string]$r.AccessControlType -eq 'Allow' -and [string]$r.InheritanceFlags -eq 'ContainerInherit, ObjectInherit') {{ $users = $users -bor (Mask $r) }} }}\n" +
        "if (($users -band $want) -ne $want) {{ $bad.Add('Users holds ' + $users + ' on the working directory, wanted ' + $want) }}\n" +
        "$fo = 0\n" +
        "foreach ($r in (Rules 'C:\\weave-files-seed\\flagdir')) {{ if ($r.IdentityReference.Value -eq 'S-1-5-32-545' -and [string]$r.InheritanceFlags -eq 'ContainerInherit, ObjectInherit' -and ((Mask $r) -band 0x301BF) -eq 0x301BF) {{ $fo++ }} }}\n" +
        "if ($fo -eq 0) {{ $bad.Add('flagdir has no inheritable Users Modify rule') }}\n" +
        "$owner = (Get-Item -LiteralPath 'C:\\weave-files-seed\\owned.txt').GetAccessControl('Owner').GetOwner($sid).Value\n" +
        "if ($owner -ne 'S-1-5-32-551') {{ $bad.Add('owned.txt is owned by ' + $owner) }}\n" +
        "$ni = (Get-Item -LiteralPath 'C:\\weave-files-seed\\noinherit').GetAccessControl('Access')\n" +
        "if (-not $ni.AreAccessRulesProtected) {{ $bad.Add('noinherit still inherits') }}\n" +
        "$niIds = @(Rules 'C:\\weave-files-seed\\noinherit' | ForEach-Object {{ $_.IdentityReference.Value }})\n" +
        "foreach ($s in 'S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545') {{ if ($niIds -notcontains $s) {{ $bad.Add('noinherit lost the rule for ' + $s) }} }}\n" +
        "$ex = @(Rules 'C:\\weave-files-seed\\exact' | ForEach-Object {{ $_.IdentityReference.Value + '/' + $_.AccessControlType }} | Sort-Object)\n" +
        "if (($ex -join ',') -ne 'S-1-5-18/Allow,S-1-5-32-544/Allow,S-1-5-32-546/Deny') {{ $bad.Add('exact holds ' + ($ex -join ',')) }}\n" +
        "Link 'C:\\weave-files-test-link' 'SymbolicLink' 'C:\\weave-files-test'\n" +
        "if (-not (Test-Path -LiteralPath 'C:\\weave-files-test-link\\hello.txt')) {{ $bad.Add('the directory link does not resolve') }}\n" +
        "Link 'C:\\weave-files-seed\\dangling' 'SymbolicLink' 'C:\\weave-files-seed\\not-yet.txt'\n" +
        "Link 'C:\\weave-files-seed\\junc' 'Junction' 'C:\\weave-files-test'\n" +
        "Link 'C:\\weave-files-seed\\oldlink' 'SymbolicLink' 'C:\\weave-files-test'\n" +
        "$bad -join '; '\n"
    )?
    if !out.success { return Err(common::failure("verify", out)) }
    let problems = out.stdout.trim()
    if problems != "" { return Err(problems) }
    Ok(true)
}
