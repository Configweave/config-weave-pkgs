use value
use common

fn validate(params: Value) -> Result[List[string], string] {
    let group = common::param_str(params, "group", "")
    common::account_name("group", group)?
    let member = common::param_str(params, "member", "")
    if member == "" { return Err("missing 'member' parameter") }
    common::single_line("member", member)?
    Ok([group, member])
}

// PowerShell binding $mdn to the member's distinguished name, or $null when
// no object matches. The member is a DN (it holds '='), a SID string, or a
// sAMAccountName (a computer's ends in '$').
fn resolve_member(member: string) -> string {
    let lookup = if member.contains("=") {
        "try {{ $mo = Get-ADObject @srv -Identity " + common::ps_q(member) + " -Properties primaryGroupID }} " +
        "catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {{ }}; "
    } else {
        let attr = if member.starts_with("S-1-") { "objectSid" } else { "sAMAccountName" }
        "$mo = @(Get-ADObject @srv -LDAPFilter " + common::ps_q("(" + attr + "=" + common::ldap_escape(member) + ")") +
        " -Properties primaryGroupID); " +
        "if ($mo.Count -gt 1) {{ throw ('more than one AD object matches ' + " + common::ps_q(member) + ") }}; " +
        "$mo = $mo | Select-Object -First 1; "
    }
    "$mo = $null; " + lookup + "$mdn = if ($mo) {{ $mo.DistinguishedName }} else {{ $null }}; "
}

// PowerShell binding $g (the group, or $null when it does not exist) and $st:
// 'NOGROUP', 'NOMEMBER' (the member resolves to nothing), 'PRIMARY' (it is
// the member's primary group), 'PRESENT' or 'ABSENT'.
//
// The test is a base-scope search for (member=<dn>) on the group, so the
// server answers it however large the group is; Get-ADGroupMember fails
// above 5000 members and on foreign security principals. A primary-group
// membership is not stored in 'member' at all, so it is read from the
// member's primaryGroupID.
fn load(group: string, member: string) -> string {
    "function Esc($s) {{ $s.Replace('\\', '\\5c').Replace('*', '\\2a').Replace('(', '\\28').Replace(')', '\\29') }}; " +
    "$g = $null; try {{ $g = Get-ADGroup @srv -Identity " + common::ps_q(group) + " -Properties primaryGroupToken }} " +
    "catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {{ }}; " +
    resolve_member(member) +
    "$st = if ($null -eq $g) {{ 'NOGROUP' }} elseif ($null -eq $mdn) {{ 'NOMEMBER' }} " +
    "elseif ($mo.primaryGroupID -and $mo.primaryGroupID -eq $g.primaryGroupToken) {{ 'PRIMARY' }} " +
    "elseif (@(Get-ADObject @srv -SearchBase $g.DistinguishedName -SearchScope Base -LDAPFilter ('(member=' + (Esc $mdn) + ')')).Count -gt 0) {{ 'PRESENT' }} " +
    "else {{ 'ABSENT' }}; "
}

fn probe(params: Value, group: string, member: string) -> Result[string, string] {
    common::ps("reading the members of AD group '" + group + "'",
        common::ad_prelude(params)? + load(group, member) + "$st")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let gm = validate(params)?
    let st = probe(params, gm[0], gm[1])?
    if common::want_present(params)? {
        if st == "PRESENT" || st == "PRIMARY" { return Ok(CheckResult::AlreadyConfigured) }
        // NOGROUP and NOMEMBER are NotConfigured too: apply reports them.
        return Ok(CheckResult::NotConfigured)
    }
    if st == "PRIMARY" {
        return Err("'" + gm[1] + "' cannot be removed from '" + gm[0] + "': it is the member's primary group (change its primary group first)")
    }
    if st == "PRESENT" { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let gm = validate(params)?
    let group = gm[0]
    let member = gm[1]
    let present = common::want_present(params)?
    // 'member' is written directly, by the DN resolved above, so the value
    // added is the value the check looks for, for any object AD allows in a
    // group (users, groups, computers, contacts).
    let body = if present {
        "if ($st -eq 'NOGROUP') {{ throw ('AD group ' + " + common::ps_q(group) + " + ' does not exist') }}; " +
        "if ($st -eq 'NOMEMBER') {{ throw ('no AD object matches ' + " + common::ps_q(member) + ") }}; " +
        "if ($st -eq 'ABSENT') {{ Set-ADObject @srv -Identity $g.ObjectGUID -Add @{{ member = $mdn }} }}"
    } else {
        "if ($st -eq 'PRIMARY') {{ throw 'it is the member''s primary group (change its primary group first)' }}; " +
        "if ($st -eq 'PRESENT') {{ Set-ADObject @srv -Identity $g.ObjectGUID -Remove @{{ member = $mdn }} }}"
    }
    let what = if present { "adding '" + member + "' to" } else { "removing '" + member + "' from" }
    common::ps(what + " AD group '" + group + "'", common::ad_prelude(params)? + load(group, member) + body)?
    Ok(ApplyResult::Success)
}
