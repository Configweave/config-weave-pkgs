use value
use log
use common

// A share name: what Windows accepts, minus the wildcards Get-SmbShare
// -Name would expand.
fn check_name(name: string) -> Result[unit, string] {
    if name == "" { return Err("missing 'name' parameter") }
    if name.len() > 80 { return Err("'name' must be at most 80 characters") }
    for c in ["\\", "/", "[", "]", ":", "|", "<", ">", "+", "=", ";", ",", "?", "*", "\"", "\n", "\r"] {
        if name.contains(c) { return Err("'name' must not contain '" + c + "', got '" + name + "'") }
    }
    Ok(())
}

fn symbol_member(params: Value, key: string, fallback: string, names: List[string], members: List[string]) -> Result[string, string] {
    let v = common::param_str(params, key, fallback)
    for i in 0..names.len() {
        if names.get(i).unwrap_or("") == v { return Ok(members.get(i).unwrap_or("")) }
    }
    Err("invalid '" + key + "' value '" + v + "' (expected :" + names.join(", :") + ")")
}

fn accounts(params: Value, key: string, right: string) -> string {
    let out = ""
    for a in common::param_strs(params, key) {
        out = out + "CwWant " + common::ps_q(a) + " '" + right + "'\n"
    }
    out
}

// PowerShell computing $s (the share or $null), $cwSet (the wanted
// settings), $cwWant (SID → { name, right }) and $drift, the list of
// differences. Every account is resolved to a SID before anything else
// runs, so a misspelt account fails check and apply alike and never
// leaves a share half-changed.
fn ps_state(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    check_name(name)?
    let path = common::param_str(params, "path", "")
    if path.contains("\n") || path.contains("\r") { return Err("'path' must not contain a line break") }
    let caching = symbol_member(params, "caching_mode", "manual",
        ["manual", "documents", "programs", "none", "branch_cache"],
        ["Manual", "Documents", "Programs", "None", "BranchCache"])?
    let enumeration = symbol_member(params, "folder_enumeration_mode", "unrestricted",
        ["unrestricted", "access_based"], ["Unrestricted", "AccessBased"])?
    let limit = common::param_int(params, "concurrent_user_limit", 0)
    if limit < 0 { return Err("'concurrent_user_limit' must be 0 (unlimited) or more") }
    let encrypt = common::param_bool(params, "encrypt_data", false)
    let desc = common::param_str(params, "description", "")
    Ok(
        "$name = " + common::ps_q(name) + "\n" +
        "$path = " + common::ps_q(path) + "\n" +
        "$desc = " + common::ps_q(desc) + "\n" +
        "$cwSet = [ordered]@{{ CachingMode = '" + caching + "'; FolderEnumerationMode = '" + enumeration + "'; ConcurrentUserLimit = [uint32]" + str(limit) + "; EncryptData = $" + (if encrypt { "true" } else { "false" }) + " }}\n" +
        "function CwSid([string]$n) {{\n" +
        "  if ($n -match '^S-\\d+-') {{ return (New-Object System.Security.Principal.SecurityIdentifier($n)).Value }}\n" +
        "  try {{ return ([System.Security.Principal.NTAccount]$n).Translate([System.Security.Principal.SecurityIdentifier]).Value }}\n" +
        "  catch {{ throw ('cannot resolve account ''' + $n + ''' to a SID') }}\n" +
        "}}\n" +
        "function CwName([string]$sid) {{\n" +
        "  try {{ (New-Object System.Security.Principal.SecurityIdentifier($sid)).Translate([System.Security.Principal.NTAccount]).Value }} catch {{ $sid }}\n" +
        "}}\n" +
        "function CwNorm([string]$p) {{\n" +
        "  $f = [IO.Path]::GetFullPath($p)\n" +
        "  if ($f.Length -gt 3) {{ $f = $f.TrimEnd('\\', '/') }}\n" +
        "  $f.ToLowerInvariant()\n" +
        "}}\n" +
        "$cwWant = [ordered]@{{}}\n" +
        "function CwWant([string]$account, [string]$right) {{\n" +
        "  $sid = CwSid $account\n" +
        "  if ($cwWant.Contains($sid) -and $cwWant[$sid].right -ne $right) {{ throw ('account ''' + $account + ''' is listed with both ' + $cwWant[$sid].right + ' and ' + $right + ' access') }}\n" +
        "  $cwWant[$sid] = [pscustomobject]@{{ name = (CwName $sid); right = $right }}\n" +
        "}}\n" +
        accounts(params, "full_access", "Full") +
        accounts(params, "change_access", "Change") +
        accounts(params, "read_access", "Read") +
        // With no grants listed at all, access is unmanaged: a new share
        // then carries Windows' default Everyone:Read entry, which an
        // exact comparison would fight forever.
        "$cwManageAccess = $cwWant.Count -gt 0\n" +
        "$s = Get-SmbShare -Name $name -ErrorAction SilentlyContinue\n" +
        "$drift = New-Object System.Collections.Generic.List[string]\n" +
        "$cwAllow = @{{}}; $cwDeny = @()\n" +
        "if ($null -ne $s) {{\n" +
        "  foreach ($e in @(Get-SmbShareAccess -Name $name)) {{\n" +
        "    $sid = try {{ CwSid $e.AccountName }} catch {{ [string]$e.AccountName }}\n" +
        "    if ([string]$e.AccessControlType -eq 'Deny') {{ $cwDeny += [pscustomobject]@{{ sid = $sid; name = [string]$e.AccountName }} }}\n" +
        "    else {{ $cwAllow[$sid] = [pscustomobject]@{{ name = [string]$e.AccountName; right = [string]$e.AccessRight }} }}\n" +
        "  }}\n" +
        "  if ($path -ne '' -and (CwNorm $s.Path) -ne (CwNorm $path)) {{ $drift.Add('path is ' + $s.Path) }}\n" +
        "  if ($desc -ne '' -and [string]$s.Description -ne $desc) {{ $drift.Add('description is ' + $s.Description) }}\n" +
        "  foreach ($k in $cwSet.Keys) {{ if ([string]$s.$k -ne [string]$cwSet[$k]) {{ $drift.Add($k + ' is ' + $s.$k + ', wanted ' + $cwSet[$k]) }} }}\n" +
        "  if ($cwManageAccess) {{\n" +
        "    foreach ($sid in $cwWant.Keys) {{ if (-not $cwAllow.ContainsKey($sid) -or $cwAllow[$sid].right -ne $cwWant[$sid].right) {{ $drift.Add($cwWant[$sid].name + ' should have ' + $cwWant[$sid].right) }} }}\n" +
        "    foreach ($sid in $cwAllow.Keys) {{ if (-not $cwWant.Contains($sid)) {{ $drift.Add($cwAllow[$sid].name + ' has unlisted ' + $cwAllow[$sid].right + ' access') }} }}\n" +
        "    foreach ($d in $cwDeny) {{ $drift.Add($d.name + ' has a Deny entry') }}\n" +
        "  }}\n" +
        "}}\n"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    let present = common::want_present(params)?
    if present && common::param_str(params, "path", "") == "" { return Err("'path' is required when ensure is :present") }
    let st = common::ps_json("reading share " + name,
        ps_state(params)? +
        "[pscustomobject]@{{ exists = ($null -ne $s); special = ($null -ne $s -and [bool]$s.Special); drift = @($drift) }} | ConvertTo-Json -Compress\n"
    )?
    let exists = common::get_bool(st, "exists")
    if !present {
        if !exists { return Ok(CheckResult::AlreadyConfigured) }
        if common::get_bool(st, "special") { return Err("refusing to remove '" + name + "': it is a special (administrative) share") }
        return Ok(CheckResult::NotConfigured)
    }
    if !exists { return Ok(CheckResult::NotConfigured) }
    let drift = common::get_list(st, "drift")
    if !drift.is_empty() {
        for d in drift { log::info("share " + name + ": " + d.as_string().unwrap_or("")) }
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    let state = ps_state(params)?
    if !common::want_present(params)? {
        log::info("removing share " + name)
        common::ps_run("removing share " + name,
            state +
            "if ($null -ne $s) {{\n" +
            "  if ($s.Special) {{ throw ('refusing to remove ' + $name + ': it is a special (administrative) share') }}\n" +
            "  Remove-SmbShare -Name $name -Force\n" +
            "}}\n"
        )?
        return Ok(ApplyResult::Success)
    }
    if common::param_str(params, "path", "") == "" { return Err("'path' is required when ensure is :present") }
    log::info("configuring share " + name)
    common::ps_run("configuring share " + name,
        state +
        // The directory first, literally (no wildcard expansion of []).
        "if (Test-Path -LiteralPath $path -PathType Leaf) {{ throw ('path ' + $path + ' is a file, not a directory') }}\n" +
        "$null = [IO.Directory]::CreateDirectory($path)\n" +
        "$new = @{{ Name = $name; Path = $path }}\n" +
        "if ($desc -ne '') {{ $new.Description = $desc }}\n" +
        "foreach ($k in $cwSet.Keys) {{ $new[$k] = $cwSet[$k] }}\n" +
        "foreach ($r in 'Full', 'Change', 'Read') {{\n" +
        "  $names = @($cwWant.Values | Where-Object {{ $_.right -eq $r }} | ForEach-Object {{ $_.name }})\n" +
        "  if ($names.Count -gt 0) {{ $new[$r + 'Access'] = $names }}\n" +
        "}}\n" +
        // Only a changed path needs the share recreated: everything else is
        // reconciled in place, so open sessions and unmanaged settings
        // survive. Every account resolved above, so the recreate cannot fail
        // on a bad account after the old share is gone.
        "if ($null -ne $s -and (CwNorm $s.Path) -ne (CwNorm $path)) {{\n" +
        "  Remove-SmbShare -Name $name -Force\n" +
        "  $s = $null\n" +
        "}}\n" +
        "if ($null -eq $s) {{ $null = New-SmbShare @new; exit 0 }}\n" +
        "$upd = @{{}}\n" +
        "if ($desc -ne '' -and [string]$s.Description -ne $desc) {{ $upd.Description = $desc }}\n" +
        "foreach ($k in $cwSet.Keys) {{ if ([string]$s.$k -ne [string]$cwSet[$k]) {{ $upd[$k] = $cwSet[$k] }} }}\n" +
        "if ($upd.Count -gt 0) {{ $null = Set-SmbShare -Name $name -Force @upd }}\n" +
        "if ($cwManageAccess) {{\n" +
        // Grant before revoking, so the share is never left with no access.
        "  foreach ($sid in $cwWant.Keys) {{\n" +
        "    $w = $cwWant[$sid]\n" +
        "    if ($cwAllow.ContainsKey($sid) -and $cwAllow[$sid].right -eq $w.right) {{ continue }}\n" +
        "    if ($cwAllow.ContainsKey($sid)) {{ $null = Revoke-SmbShareAccess -Name $name -AccountName $cwAllow[$sid].name -Force }}\n" +
        "    $null = Grant-SmbShareAccess -Name $name -AccountName $w.name -AccessRight $w.right -Force\n" +
        "  }}\n" +
        "  foreach ($sid in $cwAllow.Keys) {{ if (-not $cwWant.Contains($sid)) {{ $null = Revoke-SmbShareAccess -Name $name -AccountName $cwAllow[$sid].name -Force }} }}\n" +
        "  foreach ($d in $cwDeny) {{ $null = Unblock-SmbShareAccess -Name $name -AccountName $d.name -Force }}\n" +
        "}}\n"
    )?
    Ok(ApplyResult::Success)
}
