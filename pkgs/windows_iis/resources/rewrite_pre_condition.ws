use value
use json
use log
use common
use rewrite

// ---------------------------------------------------------------------------
// An outbound rewrite pre-condition: the gate that keeps an outbound rule off
// responses it has no business rewriting.
//
// Written whole, like the rules, because the conditions are a child
// collection rather than an attribute.
// ---------------------------------------------------------------------------

fn pre_filter() -> string { "system.webServer/rewrite/outboundRules/preConditions" }

fn pre_name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    if n == "" { return Err("missing 'name' parameter") }
    Ok(n)
}

fn element_filter(params: Value) -> Result[string, string] {
    Ok(pre_filter() + "/preCondition[@name='" + common::xp(pre_name(params)?)? + "']")
}

fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$r = @(); try {{ $r = @(Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(pre_filter() + "/preCondition") + " | Where-Object {{ [string]$_.name -eq " +
        common::ps_q(pre_name(params)?) + " }}) }} catch {{ }}; " +
        "if ($r.Count -eq 0) {{ 'ABSENT' }} else {{ $x = $r[0]; " +
        "$conds = @($x.Collection | ForEach-Object {{ " +
        "([string]$_.input + '|' + [string]$_.pattern + '|' + " +
        "([string]$_.matchType).ToLower() + '|' + ([string]$_.negate).ToLower()) }}); " +
        "[pscustomobject]@{{ logical_grouping = CwV($x.logicalGrouping); " +
        "pattern_syntax = CwV($x.patternSyntax); " +
        "conditions = ($conds -join ';;') }} | ConvertTo-Json -Compress }}")
}

fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
}

// Whether the live pre-condition already matches what this step asks for.
fn converged(params: Value) -> Result[bool, string] {
    let st = probe(params)?
    if st == "ABSENT" { return Ok(false) }
    let r = json::parse(st)?
    let grouping = rewrite::logical_grouping(common::param_str(params, "logical_grouping", ""))?
    if grouping != "" && !same(common::get_str(r, "logical_grouping"), grouping) { return Ok(false) }
    let syntax = rewrite::pattern_syntax(common::param_str(params, "pattern_syntax", ""))?
    if syntax != "" && !same(common::get_str(r, "pattern_syntax"), syntax) { return Ok(false) }
    Ok(common::get_str(r, "conditions") == rewrite::conditions_text(params)?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let r = json::parse(st)?
    let grouping = rewrite::logical_grouping(common::param_str(params, "logical_grouping", ""))?
    if grouping != "" && !same(common::get_str(r, "logical_grouping"), grouping) {
        return Ok(CheckResult::NotConfigured)
    }
    let syntax = rewrite::pattern_syntax(common::param_str(params, "pattern_syntax", ""))?
    if syntax != "" && !same(common::get_str(r, "pattern_syntax"), syntax) {
        return Ok(CheckResult::NotConfigured)
    }
    if common::get_str(r, "conditions") != rewrite::conditions_text(params)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_rewrite()?
    let name = pre_name(params)?
    let scope = common::scope_delegated(params)?
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing rewrite pre-condition " + name)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(pre_filter()) +
            " -Name '.' -AtElement @{{name=" + common::ps_q(name) + "}}")?
        return Ok(ApplyResult::Success)
    }
    if converged(params)? { return Ok(ApplyResult::Success) }
    let script = ""
    if st != "ABSENT" {
        script = script + "Remove-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(pre_filter()) + " -Name '.' -AtElement @{{name=" + common::ps_q(name) + "}}; "
    }
    script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(pre_filter()) +
        " -Name '.' -Value @{{name=" + common::ps_q(name) + "}}; "
    let elem = element_filter(params)?
    let grouping = rewrite::logical_grouping(common::param_str(params, "logical_grouping", ""))?
    if grouping != "" {
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(elem) +
            " -Name 'logicalGrouping' -Value " + common::ps_q(grouping) + "; "
    }
    let syntax = rewrite::pattern_syntax(common::param_str(params, "pattern_syntax", ""))?
    if syntax != "" {
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(elem) +
            " -Name 'patternSyntax' -Value " + common::ps_q(syntax) + "; "
    }
    for spec in common::param_list(params, "conditions") {
        let c = rewrite::parse_condition(spec)?
        script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(elem) +
            " -Name '.' -Value @{{input=" + common::ps_q(c.get(0).unwrap_or("")) + "; pattern=" +
            common::ps_q(c.get(1).unwrap_or("")) + "; matchType=" + common::ps_q(c.get(2).unwrap_or("")) +
            "; negate=" + (if c.get(3).unwrap_or("") == "true" { "$true" } else { "$false" }) + "}}; "
    }
    log::info("writing rewrite pre-condition " + name)
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
