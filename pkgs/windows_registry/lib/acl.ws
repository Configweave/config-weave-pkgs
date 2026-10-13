// The PowerShell half of the key resource's owner and permission handling.
// Masks are compared in PowerShell because they are bit sets: a merged ACE
// reports one composite name (ReadKey, WriteKey) for what was asked as two,
// and only `(have -band want) -eq want` survives that.
use common

// One "identity:rights" spec → [identity, rights]. The rights may be a
// comma-separated RegistryRights list ("ReadKey, WriteKey"), so the spec is
// split at its last colon.
fn spec_parts(spec: string) -> Result[List[string], string] {
    let parts = spec.split(":")
    if parts.len() >= 2 {
        let rights = parts.get(parts.len() - 1).unwrap_or("").trim()
        let ident = spec.slice(0, spec.len() - parts.get(parts.len() - 1).unwrap_or("").len() - 1).trim()
        if ident != "" && rights != "" && !spec.contains("\n") && !spec.contains("\r") { return Ok([ident, rights]) }
    }
    Err("invalid permission '" + spec + "' (expected \"identity:rights\", e.g. \"BUILTIN\\Users:ReadKey\")")
}

// PowerShell defining the wanted owner ($cwOwner, "" for unmanaged), the
// wanted rules ($cwWant, grouped by SID so overlapping specs merge into one
// mask), $cwExact, and the helper functions. Every account is resolved to a
// SID here, so an unknown account fails check and apply alike, and a name
// that is spelled differently from what the ACL reports still matches.
fn ps_prelude(owner: string, specs: List[string], exact: bool) -> Result[string, string] {
    let adds: List[string] = []
    for spec in specs {
        let pp = spec_parts(spec)?
        adds.push("CwAddWant " + common::ps_q(pp.get(0).unwrap_or("")) + " " + common::ps_q(pp.get(1).unwrap_or("")) + "\n")
    }
    Ok(
        "$cwExact = $" + (if exact { "true" } else { "false" }) + "\n" +
        "function CwSid([string]$n) {{\n" +
        "  if ($n -match '^S-\\d+-') {{ return (New-Object System.Security.Principal.SecurityIdentifier($n)).Value }}\n" +
        "  try {{ return ([System.Security.Principal.NTAccount]$n).Translate([System.Security.Principal.SecurityIdentifier]).Value }}\n" +
        "  catch {{ throw ('cannot resolve account ''' + $n + ''' to a SID') }}\n" +
        "}}\n" +
        "function CwMask($v) {{ [int64]([int]$v) -band 0xFFFFFFFFL }}\n" +
        // Wanted rules are what .NET itself would store for the spec.
        "function CwRule([string]$sid, $mask, [string]$type) {{\n" +
        "  New-Object System.Security.AccessControl.RegistryAccessRule((New-Object System.Security.Principal.SecurityIdentifier($sid)), [System.Security.AccessControl.RegistryRights][int]$mask, 'ContainerInherit', 'None', $type)\n" +
        "}}\n" +
        "$cwWant = [ordered]@{{}}\n" +
        "function CwAddWant([string]$ident, [string]$rights) {{\n" +
        "  $sid = CwSid $ident\n" +
        "  try {{ $r = [System.Security.AccessControl.RegistryRights]$rights }} catch {{ throw ('invalid registry rights ''' + $rights + ''' for ' + $ident + ': use RegistryRights names such as ReadKey, WriteKey or FullControl') }}\n" +
        "  $key = $sid + '|Allow'\n" +
        "  $m = CwMask $r\n" +
        "  if ($cwWant.Contains($key)) {{ $m = $m -bor $cwWant[$key].mask }}\n" +
        "  $cwWant[$key] = [pscustomobject]@{{ sid = $sid; type = 'Allow'; mask = (CwMask (CwRule $sid $m 'Allow').RegistryRights) }}\n" +
        "}}\n" +
        // An explicit rule counts towards a want only when it applies to the
        // key itself and to every subkey below it.
        "function CwFlagsOk($r) {{ (($r.InheritanceFlags -band [System.Security.AccessControl.InheritanceFlags]::ContainerInherit) -ne 0) -and ([string]$r.PropagationFlags -eq 'None') }}\n" +
        "function CwExplicit($acl) {{ @($acl.GetAccessRules($true, $false, [System.Security.Principal.SecurityIdentifier])) }}\n" +
        // Each want with whether the explicit rules satisfy it, plus the
        // explicit rules nothing asked for (drift only in exact mode).
        "function CwEval($acl) {{\n" +
        "  $explicit = CwExplicit $acl\n" +
        "  $drift = New-Object System.Collections.Generic.List[string]\n" +
        "  foreach ($w in $cwWant.Values) {{\n" +
        "    $have = [int64]0; $odd = $false\n" +
        "    foreach ($r in $explicit) {{\n" +
        "      if ($r.IdentityReference.Value -ne $w.sid -or [string]$r.AccessControlType -ne $w.type) {{ continue }}\n" +
        "      if (CwFlagsOk $r) {{ $have = $have -bor (CwMask $r.RegistryRights) }} else {{ $odd = $true }}\n" +
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
        adds.join("")
    )
}
