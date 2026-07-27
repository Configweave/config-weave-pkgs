use value
use shell
use json

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

// The params are lowercase symbols, matching this library's convention; AD
// speaks PascalCase and `[string]$g.GroupScope` reports it that way, so the
// symbol is translated once here and that spelling is used for both the
// comparison in `check` and the cmdlet arguments in `apply`.
fn ad_scope(params: Value) -> Result[string, string] {
    let s = param_str(params, "scope", "global")
    if s == "global" { return Ok("Global") }
    if s == "universal" { return Ok("Universal") }
    if s == "domainlocal" { return Ok("DomainLocal") }
    Err("invalid 'scope' value '" + s + "' (expected :global, :universal or :domainlocal)")
}

fn ad_category(params: Value) -> Result[string, string] {
    let c = param_str(params, "category", "security")
    if c == "security" { return Ok("Security") }
    if c == "distribution" { return Ok("Distribution") }
    Err("invalid 'category' value '" + c + "' (expected :security or :distribution)")
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

fn ad_guard() -> string {
    "if (-not (Get-Module -ListAvailable ActiveDirectory)) {{ throw 'the ActiveDirectory PowerShell module is required' }}; " +
    "Import-Module ActiveDirectory; "
}

fn fetch(name: string) -> string {
    "$g = $null; try {{ $g = Get-ADGroup -Identity " + ps_q(name) + " }} " +
    "catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {{ }}; "
}

// 'ABSENT' or a JSON object { scope, category }.
fn probe(name: string) -> Result[string, string] {
    ps_out(
        ad_guard() + fetch(name) +
        "if ($null -eq $g) {{ 'ABSENT' }} else {{ " +
        "[pscustomobject]@{{ scope = [string]$g.GroupScope; category = [string]$g.GroupCategory }} | ConvertTo-Json -Compress }}"
    )
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let st = probe(name)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    // ou_path is create-only placement, so the DN is not compared.
    let g = json::parse(st)?
    if get_str(g, "scope") != ad_scope(params)? { return Ok(CheckResult::NotConfigured) }
    if get_str(g, "category") != ad_category(params)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = ps_q(name)
    if !want_present(params)? {
        ps_run(ad_guard() + fetch(name) + "if ($g) {{ Remove-ADGroup -Identity " + qn + " -Confirm:$false }}")?
        return Ok(ApplyResult::Success)
    }
    let scope = ps_q(ad_scope(params)?)
    let category = ps_q(ad_category(params)?)
    let ou = param_str(params, "ou_path", "")
    let create = "New-ADGroup -Name " + qn + " -SamAccountName " + qn +
        " -GroupScope " + scope + " -GroupCategory " + category +
        (if ou != "" { " -Path " + ps_q(ou) } else { "" })
    // Note: AD only allows some direct scope transitions (Global <-> Universal
    // <-> DomainLocal via Universal); an illegal transition surfaces AD's error.
    let update = "Set-ADGroup -Identity " + qn + " -GroupScope " + scope + " -GroupCategory " + category
    ps_run(
        ad_guard() + fetch(name) +
        "if ($null -eq $g) {{ " + create + " }} else {{ " + update + " }}"
    )?
    Ok(ApplyResult::Success)
}
