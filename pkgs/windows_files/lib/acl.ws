// The PowerShell half of the permissions resource. Masks are compared in
// PowerShell because they are bit sets: a merged ACE reports one composite
// name (Modify) for what was asked as several, generic or unusual
// combinations print as numbers, and only `(have -band want) -eq want`
// survives that.
use common

// One "identity:rights" spec → [identity, rights]. The rights may be a
// comma-separated FileSystemRights list ("Read, Write"), so the spec is
// split at its last colon.
fn spec_parts(spec: string) -> Result[List[string], string] {
    let parts = spec.split(":")
    if parts.len() >= 2 {
        let last = parts.get(parts.len() - 1).unwrap_or("")
        let rights = last.trim()
        let ident = spec.slice(0, spec.len() - last.len() - 1).trim()
        if ident != "" && rights != "" && !spec.contains("\n") && !spec.contains("\r") { return Ok([ident, rights]) }
    }
    Err("invalid rule '" + spec + "' (expected \"identity:rights\", e.g. \"BUILTIN\\Users:ReadAndExecute\")")
}

fn adds(specs: List[string], kind: string) -> Result[string, string] {
    let out = ""
    for spec in specs {
        let pp = spec_parts(spec)?
        out = out + "CwAddWant " + common::ps_q(pp.get(0).unwrap_or("")) + " " + common::ps_q(pp.get(1).unwrap_or("")) + " '" + kind + "'\n"
    }
    Ok(out)
}

// PowerShell defining $cwPath, $cwIsDir, the wanted owner ($cwOwner, ""
// for unmanaged), the wanted rules ($cwWant, grouped by SID and type so
// overlapping specs merge into one mask), $cwExact, and the helpers. Every
// account is resolved to a SID here, so an unknown account fails check and
// apply alike, and a localised or unqualified name still matches.
fn ps_prelude(p: string, owner: string, allow: List[string], deny: List[string], exact: bool) -> Result[string, string] {
    Ok(
        "$cwPath = " + common::ps_q(p) + "\n" +
        "$cwItem = Get-Item -LiteralPath $cwPath -Force\n" +
        "$cwIsDir = [bool]$cwItem.PSIsContainer\n" +
        "$cwExact = $" + (if exact { "true" } else { "false" }) + "\n" +
        // Directory rules apply to the folder, subfolders and files; a file
        // cannot carry inheritance flags.
        "$cwInh = if ($cwIsDir) {{ [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit' }} else {{ [System.Security.AccessControl.InheritanceFlags]::None }}\n" +
        "function CwSid([string]$n) {{\n" +
        "  if ($n -match '^S-\\d+-') {{ return (New-Object System.Security.Principal.SecurityIdentifier($n)).Value }}\n" +
        "  try {{ return ([System.Security.Principal.NTAccount]$n).Translate([System.Security.Principal.SecurityIdentifier]).Value }}\n" +
        "  catch {{ throw ('cannot resolve account ''' + $n + ''' to a SID') }}\n" +
        "}}\n" +
        "function CwMask($v) {{ [int64]([int]$v) -band 0xFFFFFFFFL }}\n" +
        // Wanted masks are what .NET itself stores for the spec, which for
        // an Allow rule includes Synchronize.
        "function CwRule([string]$sid, $mask, [string]$type) {{\n" +
        "  New-Object System.Security.AccessControl.FileSystemAccessRule((New-Object System.Security.Principal.SecurityIdentifier($sid)), [System.Security.AccessControl.FileSystemRights][int]$mask, $cwInh, 'None', $type)\n" +
        "}}\n" +
        "$cwWant = [ordered]@{{}}\n" +
        "function CwAddWant([string]$ident, [string]$rights, [string]$type) {{\n" +
        "  $sid = CwSid $ident\n" +
        "  try {{ $r = [System.Security.AccessControl.FileSystemRights]$rights }} catch {{ throw ('invalid file system rights ''' + $rights + ''' for ' + $ident + ': use FileSystemRights names such as ReadAndExecute, Modify, Read, Write or FullControl') }}\n" +
        "  $key = $sid + '|' + $type\n" +
        "  $m = CwMask $r\n" +
        "  if ($cwWant.Contains($key)) {{ $m = $m -bor $cwWant[$key].mask }}\n" +
        "  $cwWant[$key] = [pscustomobject]@{{ sid = $sid; type = $type; mask = (CwMask (CwRule $sid $m $type).FileSystemRights) }}\n" +
        "}}\n" +
        // An explicit rule counts towards a want only when it covers the
        // path itself and, on a directory, everything below it: an
        // InheritOnly or this-folder-only rule does not.
        "function CwFlagsOk($r) {{ ($r.InheritanceFlags -eq $cwInh) -and ([string]$r.PropagationFlags -eq 'None') }}\n" +
        "function CwExplicit($acl) {{ @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) }}\n" +
        // The drift between the explicit rules and the wants. Each want is
        // marked ok or not; in exact mode an unlisted explicit rule is drift.
        "function CwEval($acl) {{\n" +
        "  $explicit = CwExplicit $acl\n" +
        "  $drift = New-Object System.Collections.Generic.List[string]\n" +
        "  foreach ($w in $cwWant.Values) {{\n" +
        "    $have = [int64]0; $odd = $false\n" +
        "    foreach ($r in $explicit) {{\n" +
        "      if ($r.IdentityReference.Value -ne $w.sid -or [string]$r.AccessControlType -ne $w.type) {{ continue }}\n" +
        "      if (CwFlagsOk $r) {{ $have = $have -bor (CwMask $r.FileSystemRights) }} else {{ $odd = $true }}\n" +
        "    }}\n" +
        "    $ok = (($have -band $w.mask) -eq $w.mask)\n" +
        "    if ($cwExact -and ($odd -or $have -ne $w.mask)) {{ $ok = $false }}\n" +
        "    $w | Add-Member -NotePropertyName ok -NotePropertyValue $ok -Force\n" +
        "    if (-not $ok) {{ $drift.Add($w.type + ' ' + $w.sid + ' wants mask ' + $w.mask + ', explicit rules give ' + $have) }}\n" +
        "  }}\n" +
        "  if ($cwExact) {{\n" +
        "    foreach ($r in $explicit) {{\n" +
        "      if (-not $cwWant.Contains($r.IdentityReference.Value + '|' + [string]$r.AccessControlType)) {{ $drift.Add('unlisted explicit ' + [string]$r.AccessControlType + ' rule for ' + $r.IdentityReference.Value) }}\n" +
        "    }}\n" +
        "  }}\n" +
        "  ,$drift\n" +
        "}}\n" +
        // Setting an owner other than the caller needs SeRestorePrivilege,
        // which SYSTEM holds but has disabled.
        "function CwEnableOwnerPrivileges {{\n" +
        "  if (-not ('CwPrivilege' -as [type])) {{\n" +
        "    Add-Type -TypeDefinition @'\n" +
        "using System;\n" +
        "using System.Runtime.InteropServices;\n" +
        "public static class CwPrivilege {{\n" +
        "  [StructLayout(LayoutKind.Sequential, Pack = 1)] struct TokPriv {{ public int Count; public long Luid; public int Attr; }}\n" +
        "  [DllImport(\"advapi32.dll\", SetLastError = true)] static extern bool OpenProcessToken(IntPtr h, int access, out IntPtr token);\n" +
        "  [DllImport(\"advapi32.dll\", SetLastError = true)] static extern bool LookupPrivilegeValue(string host, string name, out long luid);\n" +
        "  [DllImport(\"advapi32.dll\", SetLastError = true)] static extern bool AdjustTokenPrivileges(IntPtr token, bool all, ref TokPriv state, int len, IntPtr prev, IntPtr ret);\n" +
        "  [DllImport(\"kernel32.dll\")] static extern IntPtr GetCurrentProcess();\n" +
        "  public static void Enable(string name) {{\n" +
        "    IntPtr token;\n" +
        "    if (!OpenProcessToken(GetCurrentProcess(), 0x28, out token)) throw new System.ComponentModel.Win32Exception();\n" +
        "    TokPriv tp; tp.Count = 1; tp.Attr = 2;\n" +
        "    if (!LookupPrivilegeValue(null, name, out tp.Luid)) throw new System.ComponentModel.Win32Exception();\n" +
        "    if (!AdjustTokenPrivileges(token, false, ref tp, 0, IntPtr.Zero, IntPtr.Zero)) throw new System.ComponentModel.Win32Exception();\n" +
        "  }}\n" +
        "}}\n" +
        "'@\n" +
        "  }}\n" +
        "  foreach ($p in 'SeRestorePrivilege', 'SeTakeOwnershipPrivilege') {{ try {{ [CwPrivilege]::Enable($p) }} catch {{ }} }}\n" +
        "}}\n" +
        "$cwOwner = ''\n" +
        (if owner != "" { "$cwOwner = CwSid " + common::ps_q(owner) + "\n" } else { "" }) +
        adds(allow, "Allow")? +
        adds(deny, "Deny")?
    )
}
