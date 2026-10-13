use value
use common

fn validate(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    common::account_name("name", name)?
    common::single_line("description", common::param_str(params, "description", ""))?
    Ok(name)
}

// PowerShell binding $g to the group, or $null when it does not exist. Only
// "not found" reads as absent; access denied or any other failure throws.
fn fetch(name: string) -> string {
    "$g = $null; try {{ $g = Get-LocalGroup -Name " + common::ps_q(name) + " }} " +
    "catch [Microsoft.PowerShell.Commands.GroupNotFoundException] {{ }}; "
}

// 'ABSENT' or a JSON object { description }.
fn probe(name: string) -> Result[string, string] {
    common::ps("reading local group '" + name + "'",
        fetch(name) +
        "if ($null -eq $g) {{ 'ABSENT' }} else {{ " +
        "[pscustomobject]@{{ description = [string]$g.Description }} | ConvertTo-Json -Compress }}"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = validate(params)?
    let st = probe(name)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let desc = common::param_str(params, "description", "")
    if desc != "" && common::get_str(common::parse_json(st)?, "description") != desc { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = validate(params)?
    let qn = common::ps_q(name)
    if !common::want_present(params)? {
        common::ps("removing local group '" + name + "'", fetch(name) + "if ($g) {{ Remove-LocalGroup -SID $g.SID }}")?
        return Ok(ApplyResult::Success)
    }
    let desc = common::param_str(params, "description", "")
    let desc_arg = if desc != "" { " -Description " + common::ps_q(desc) } else { "" }
    let update = if desc != "" { "Set-LocalGroup -SID $g.SID" + desc_arg } else { "" }
    common::ps("configuring local group '" + name + "'",
        fetch(name) +
        "if ($null -eq $g) {{ New-LocalGroup -Name " + qn + desc_arg + " | Out-Null }} " +
        "else {{ " + update + " }}"
    )?
    Ok(ApplyResult::Success)
}
