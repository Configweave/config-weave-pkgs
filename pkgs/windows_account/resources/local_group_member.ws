use value
use common

// The member as the account name Windows resolves. A bare name means the
// local account of that name (COMPUTERNAME\name) and nothing else, so a bare
// "admin" can never select CORP\admin. Qualified names (DOMAIN\name,
// NT AUTHORITY\name), UPNs and SID strings pass through.
fn qualified_member(member: string) -> string {
    if member.contains("\\") || member.contains("@") || member.starts_with("S-1-") { return common::ps_q(member) }
    "($env:COMPUTERNAME + '\\' + " + common::ps_q(member) + ")"
}

fn validate(params: Value) -> Result[List[string], string] {
    let group = common::param_str(params, "group", "")
    common::account_name("group", group)?
    let member = common::param_str(params, "member", "")
    if member == "" { return Err("missing 'member' parameter") }
    common::single_line("member", member)?
    if member.contains("\\") {
        let parts = member.split("\\")
        if parts.len() != 2 || parts[0] == "" { return Err("'member' must be NAME, DOMAIN\\NAME, a UPN or a SID, got '" + member + "'") }
        common::account_name("member", parts[1])?
    } else if !member.contains("@") && !member.starts_with("S-1-") {
        common::account_name("member", member)?
    }
    Ok([group, member])
}

// PowerShell binding $grp (the ADSI group, or $null when the group does not
// exist), $sid (the member's SID string, or $null when the name resolves to
// no account) and $sids (the SIDs of every current member).
//
// Membership is read through ADSI rather than Get-LocalGroupMember, which
// fails outright (error 1789) on a group holding an orphaned SID and would
// otherwise hide every other member. SIDs make the comparison exact.
fn load(group: string, member: string) -> string {
    "$grp = $null; $sid = $null; $sids = @(); " +
    "$lg = $null; try {{ $lg = Get-LocalGroup -Name " + common::ps_q(group) + " }} " +
    "catch [Microsoft.PowerShell.Commands.GroupNotFoundException] {{ }}; " +
    "$m = " + qualified_member(member) + "; " +
    "if ($m -like 'S-1-*') {{ $sid = (New-Object System.Security.Principal.SecurityIdentifier($m)).Value }} else {{ " +
    "try {{ $sid = (New-Object System.Security.Principal.NTAccount($m)).Translate([System.Security.Principal.SecurityIdentifier]).Value }} " +
    "catch [System.Security.Principal.IdentityNotMappedException] {{ }} }}; " +
    "if ($lg) {{ " +
    "$grp = [ADSI]('WinNT://' + $env:COMPUTERNAME + '/' + $lg.Name + ',group'); " +
    "$sids = @($grp.psbase.Invoke('Members') | ForEach-Object {{ " +
    "$b = $_.GetType().InvokeMember('objectSid', 'GetProperty', $null, $_, $null); " +
    "(New-Object System.Security.Principal.SecurityIdentifier($b, 0)).Value }}) }}; "
}

// 'NOGROUP', 'PRESENT' or 'ABSENT'.
fn probe(group: string, member: string) -> Result[string, string] {
    common::ps("reading the members of local group '" + group + "'",
        load(group, member) +
        "if ($null -eq $grp) {{ 'NOGROUP' }} elseif ($sid -and ($sids -contains $sid)) {{ 'PRESENT' }} else {{ 'ABSENT' }}"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let gm = validate(params)?
    let st = probe(gm[0], gm[1])?
    if common::want_present(params)? {
        if st == "PRESENT" { return Ok(CheckResult::AlreadyConfigured) }
        // NOGROUP is NotConfigured too: apply then reports the missing group.
        return Ok(CheckResult::NotConfigured)
    }
    if st == "PRESENT" { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let gm = validate(params)?
    let group = gm[0]
    let member = gm[1]
    let present = common::want_present(params)?
    let body = if present {
        "if ($null -eq $grp) {{ throw ('local group ' + " + common::ps_q(group) + " + ' does not exist') }}; " +
        "if ($null -eq $sid) {{ throw ('no account named ' + $m + ' exists') }}; " +
        "if ($sids -notcontains $sid) {{ $grp.Add('WinNT://' + $sid) }}"
    } else {
        // Exactly one SID is removed: the one the member name resolves to.
        "if ($grp -and $sid -and ($sids -contains $sid)) {{ $grp.Remove('WinNT://' + $sid) }}"
    }
    let what = if present { "adding '" + member + "' to" } else { "removing '" + member + "' from" }
    common::ps(what + " local group '" + group + "'", load(group, member) + body)?
    Ok(ApplyResult::Success)
}
