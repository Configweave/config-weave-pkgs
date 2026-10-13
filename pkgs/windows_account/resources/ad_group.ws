use value
use common

// The params are lowercase symbols, matching this library's convention; AD
// speaks PascalCase and `[string]$g.GroupScope` reports it that way, so the
// symbol is translated once here and that spelling is used for both the
// comparison in `check` and the cmdlet arguments in `apply`.
fn ad_scope(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "scope", "global")
    if s == "global" { return Ok("Global") }
    if s == "universal" { return Ok("Universal") }
    if s == "domainlocal" { return Ok("DomainLocal") }
    Err("invalid 'scope' value '" + s + "' (expected :global, :universal or :domainlocal)")
}

fn ad_category(params: Value) -> Result[string, string] {
    let c = common::param_str(params, "category", "security")
    if c == "security" { return Ok("Security") }
    if c == "distribution" { return Ok("Distribution") }
    Err("invalid 'category' value '" + c + "' (expected :security or :distribution)")
}

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::account_name("name", name)?
    common::single_line("ou_path", common::param_str(params, "ou_path", ""))?
    ad_scope(params)?
    ad_category(params)?
    Ok(name)
}

fn fetch(name: string) -> string {
    "$g = $null; try {{ $g = Get-ADGroup @srv -Identity " + common::ps_q(name) + " }} " +
    "catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {{ }}; "
}

// 'ABSENT' or a JSON object { scope, category, ou_ok }.
fn probe(params: Value, name: string) -> Result[string, string] {
    let ou = common::param_str(params, "ou_path", "")
    common::ps("reading AD group '" + name + "'",
        common::ad_prelude(params)? + fetch(name) +
        "if ($null -eq $g) {{ 'ABSENT' }} else {{ $dn = $g.DistinguishedName; " + common::ou_match_ps(ou) +
        "[pscustomobject]@{{ scope = [string]$g.GroupScope; category = [string]$g.GroupCategory; ou_ok = [bool]$ouOk }} | ConvertTo-Json -Compress }}"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let st = probe(params, name)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let g = common::parse_json(st)?
    if common::get_str(g, "scope") != ad_scope(params)? { return Ok(CheckResult::NotConfigured) }
    if common::get_str(g, "category") != ad_category(params)? { return Ok(CheckResult::NotConfigured) }
    if !common::get_bool(g, "ou_ok") { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let qn = common::ps_q(name)
    let prelude = common::ad_prelude(params)?
    if !common::want_present(params)? {
        common::ps("removing AD group '" + name + "'",
            prelude + fetch(name) + "if ($g) {{ Remove-ADGroup @srv -Identity $g.ObjectGUID -Confirm:$false }}")?
        return Ok(ApplyResult::Success)
    }
    let scope = common::ps_q(ad_scope(params)?)
    let category = common::ps_q(ad_category(params)?)
    let ou = common::param_str(params, "ou_path", "")
    let create = "New-ADGroup @srv -Name " + qn + " -SamAccountName " + qn +
        " -GroupScope " + scope + " -GroupCategory " + category +
        (if ou != "" { " -Path " + common::ps_q(ou) } else { "" }) + "; "
    // AD has no direct Global <-> DomainLocal conversion, only each of them to
    // and from Universal, so such a change steps through Universal. AD still
    // refuses a step the members rule out (a Global group cannot become
    // Universal while it is a member of another Global group, for example),
    // and that error is surfaced.
    let rescope = "$want = " + scope + "; $cur = [string]$g.GroupScope; " +
        "if ($cur -ne $want) {{ " +
        "if ($cur -ne 'Universal' -and $want -ne 'Universal') {{ Set-ADGroup @srv -Identity $g.ObjectGUID -GroupScope Universal }}; " +
        "Set-ADGroup @srv -Identity $g.ObjectGUID -GroupScope $want }}; "
    let move = if ou != "" {
        "$dn = $g.DistinguishedName; " + common::ou_match_ps(ou) +
        "if (-not $ouOk) {{ Move-ADObject @srv -Identity $g.ObjectGUID -TargetPath $ouObj.DistinguishedName }}; "
    } else { "" }
    let update = rescope + "Set-ADGroup @srv -Identity $g.ObjectGUID -GroupCategory " + category + "; " + move
    common::ps("configuring AD group '" + name + "'",
        prelude + fetch(name) +
        "if ($null -eq $g) {{ " + create + "}} else {{ " + update + "}}"
    )?
    Ok(ApplyResult::Success)
}
