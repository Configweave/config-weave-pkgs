use value
use json
use log
use common
use rewrite

// ---------------------------------------------------------------------------
// An outbound URL Rewrite rule: one that rewrites the response rather than
// the request.
//
// Written whole for the same reason as the inbound rule — it is four elements
// and IIS has no "patch a rule" operation.
//
// An outbound rule without a pre_condition is evaluated against every
// response the site produces, including images and downloads, so the
// pre-condition is not just an optimisation.
// ---------------------------------------------------------------------------

fn rules_filter() -> string { "system.webServer/rewrite/outboundRules" }

fn rule_name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    if n == "" { return Err("missing 'name' parameter") }
    Ok(n)
}

fn rule_filter(params: Value) -> Result[string, string] {
    Ok(rules_filter() + "/rule[@name='" + common::xp(rule_name(params)?)? + "']")
}

fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$r = @(); try {{ $r = @(Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(rules_filter() + "/rule") + " | Where-Object {{ [string]$_.name -eq " +
        common::ps_q(rule_name(params)?) + " }}) }} catch {{ }}; " +
        "if ($r.Count -eq 0) {{ 'ABSENT' }} else {{ $x = $r[0]; " +
        "$conds = @($x.conditions.Collection | ForEach-Object {{ " +
        "([string]$_.input + '|' + [string]$_.pattern + '|' + " +
        "([string]$_.matchType).ToLower() + '|' + ([string]$_.negate).ToLower()) }}); " +
        "[pscustomobject]@{{ " +
        "enabled = CwV($x.enabled); stop_processing = CwV($x.stopProcessing); " +
        "pattern_syntax = CwV($x.patternSyntax); pre_condition = CwV($x.preCondition); " +
        "match_server_variable = CwV($x.match.serverVariable); " +
        "filter_by_tags = CwV($x.match.filterByTags); pattern = CwV($x.match.pattern); " +
        "ignore_case = CwV($x.match.ignoreCase); negate = CwV($x.match.negate); " +
        "conditions_logical_grouping = CwV($x.conditions.logicalGrouping); " +
        "action_value = CwV($x.action.value); " +
        "replace_server_variable = CwV($x.action.replace); " +
        "conditions = ($conds -join ';;') }} | ConvertTo-Json -Compress }}")
}

fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
}

// [probe key, desired text, element suffix, IIS attribute, kind]
fn wanted(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    if common::has(params, "enabled") {
        out.push(["enabled", if common::param_bool(params, "enabled", true) { "true" } else { "false" },
            "", "enabled", "bool"])
    }
    if common::has(params, "stop_processing") {
        out.push(["stop_processing",
            if common::param_bool(params, "stop_processing", false) { "true" } else { "false" },
            "", "stopProcessing", "bool"])
    }
    let syntax = rewrite::pattern_syntax(common::param_str(params, "pattern_syntax", ""))?
    if syntax != "" { out.push(["pattern_syntax", syntax, "", "patternSyntax", "str"]) }
    let pre = common::param_str(params, "pre_condition", "")
    if pre != "" { out.push(["pre_condition", pre, "", "preCondition", "str"]) }
    let sv = common::param_str(params, "match_server_variable", "")
    if sv != "" { out.push(["match_server_variable", sv, "/match", "serverVariable", "str"]) }
    let tags = common::param_str(params, "filter_by_tags", "")
    if tags != "" { out.push(["filter_by_tags", tags, "/match", "filterByTags", "str"]) }
    let pattern = common::param_str(params, "pattern", "")
    if pattern != "" { out.push(["pattern", pattern, "/match", "pattern", "str"]) }
    if common::has(params, "ignore_case") {
        out.push(["ignore_case", if common::param_bool(params, "ignore_case", true) { "true" } else { "false" },
            "/match", "ignoreCase", "bool"])
    }
    if common::has(params, "negate") {
        out.push(["negate", if common::param_bool(params, "negate", false) { "true" } else { "false" },
            "/match", "negate", "bool"])
    }
    let grouping = rewrite::logical_grouping(common::param_str(params, "conditions_logical_grouping", ""))?
    if grouping != "" {
        out.push(["conditions_logical_grouping", grouping, "/conditions", "logicalGrouping", "str"])
    }
    let value = common::param_str(params, "action_value", "")
    if value != "" { out.push(["action_value", value, "/action", "value", "str"]) }
    if common::has(params, "replace_server_variable") {
        out.push(["replace_server_variable",
            if common::param_bool(params, "replace_server_variable", false) { "true" } else { "false" },
            "/action", "replace", "bool"])
    }
    Ok(out)
}

// Whether the live rule already matches everything this step asks for.
fn converged(params: Value) -> Result[bool, string] {
    let st = probe(params)?
    if st == "ABSENT" { return Ok(false) }
    let r = json::parse(st)?
    for row in wanted(params)? {
        if !same(common::get_str(r, row.get(0).unwrap_or("")), row.get(1).unwrap_or("")) {
            return Ok(false)
        }
    }
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
    for row in wanted(params)? {
        if !same(common::get_str(r, row.get(0).unwrap_or("")), row.get(1).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    if common::get_str(r, "conditions") != rewrite::conditions_text(params)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn ps_value(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    if kind == "int" { return want }
    common::ps_q(want)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_rewrite()?
    let name = rule_name(params)?
    let scope = common::scope_delegated(params)?
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing outbound rewrite rule " + name)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
            " -Name '.' -AtElement @{{name=" + common::ps_q(name) + "}}")?
        return Ok(ApplyResult::Success)
    }
    if common::param_str(params, "pattern", "") == "" {
        return Err("'pattern' is required when ensure is :present")
    }
    if common::param_str(params, "match_server_variable", "") == "" &&
       common::param_str(params, "filter_by_tags", "") == "" {
        return Err("give either 'match_server_variable' or 'filter_by_tags' so the rule has something to match")
    }
    // Nothing differs: return without touching anything. These resources
    // rebuild the element rather than patching it, and rebuilding moves it to
    // the end of its collection — outbound rewrite rules are evaluated in order, so a converged
    // re-run must not touch them at all.
    if converged(params)? { return Ok(ApplyResult::Success) }
    let script = ""
    if st != "ABSENT" {
        script = script + "Remove-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rules_filter()) + " -Name '.' -AtElement @{{name=" + common::ps_q(name) + "}}; "
    }
    script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
        " -Name '.' -Value @{{name=" + common::ps_q(name) + "}}; "
    let rule = rule_filter(params)?
    for row in wanted(params)? {
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rule + row.get(2).unwrap_or("")) + " -Name " + common::ps_q(row.get(3).unwrap_or("")) +
            " -Value " + ps_value(row.get(4).unwrap_or(""), row.get(1).unwrap_or("")) + "; "
    }
    for spec in common::param_list(params, "conditions") {
        let c = rewrite::parse_condition(spec)?
        script = script + "Add-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rule + "/conditions") + " -Name '.' -Value @{{input=" +
            common::ps_q(c.get(0).unwrap_or("")) + "; pattern=" + common::ps_q(c.get(1).unwrap_or("")) +
            "; matchType=" + common::ps_q(c.get(2).unwrap_or("")) + "; negate=" +
            (if c.get(3).unwrap_or("") == "true" { "$true" } else { "$false" }) + "}}; "
    }
    log::info("writing outbound rewrite rule " + name)
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
