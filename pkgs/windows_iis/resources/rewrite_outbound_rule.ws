use value
use json
use log
use common
use rewrite

// ---------------------------------------------------------------------------
// An outbound URL Rewrite rule: one that rewrites the response rather than
// the request.
//
// Like the inbound rule, an existing rule is patched where it stands (see
// lib/rewrite.ws), so it keeps its place in the evaluation order.
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

fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$r = @(); try {{ $r = @(Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(rules_filter() + "/rule") + " | Where-Object {{ [string]$_.name -eq " +
        common::ps_q(rule_name(params)?) + " }}) }} catch {{ }}; " +
        "if ($r.Count -eq 0) {{ 'ABSENT' }} else {{ $x = $r[0]; " +
        "[pscustomobject]@{{ name = [string]$x.name; " +
        "enabled = CwV($x.enabled); stop_processing = CwV($x.stopProcessing); " +
        "pattern_syntax = CwV($x.patternSyntax); pre_condition = CwV($x.preCondition); " +
        "match_server_variable = CwV($x.match.serverVariable); " +
        "filter_by_tags = CwV($x.match.filterByTags); pattern = CwV($x.match.pattern); " +
        "ignore_case = CwV($x.match.ignoreCase); negate = CwV($x.match.negate); " +
        "conditions_logical_grouping = CwV($x.conditions.logicalGrouping); " +
        "action_type = CwV($x.action.type); action_value = CwV($x.action.value); " +
        "replace_server_variable = CwV($x.action.replace); " +
        "conditions = " + rewrite::read_conditions("$x.conditions.Collection") +
        " }} | ConvertTo-Json -Compress -Depth 5 }}")
}

// [probe key, desired text, element suffix, IIS attribute, kind]
fn wanted(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    if let Some(r) = rewrite::bool_row(params, "enabled", true, "", "enabled") { out.push(r) }
    if let Some(r) = rewrite::bool_row(params, "stop_processing", false, "", "stopProcessing") { out.push(r) }
    let syntax = rewrite::pattern_syntax(common::param_str(params, "pattern_syntax", ""))?
    if syntax != "" { out.push(["pattern_syntax", syntax, "", "patternSyntax", "sym"]) }
    let pre = common::param_str(params, "pre_condition", "")
    if pre != "" { out.push(["pre_condition", pre, "", "preCondition", "str"]) }
    let sv = common::param_str(params, "match_server_variable", "")
    if sv != "" { out.push(["match_server_variable", sv, "/match", "serverVariable", "sym"]) }
    // filterByTags is a flags attribute: IIS renders it in its own order and
    // spacing, so it compares as a set.
    let tags = common::param_str(params, "filter_by_tags", "")
    if tags != "" { out.push(["filter_by_tags", tags, "/match", "filterByTags", "flags"]) }
    let pattern = common::param_str(params, "pattern", "")
    if pattern != "" { out.push(["pattern", pattern, "/match", "pattern", "str"]) }
    if let Some(r) = rewrite::bool_row(params, "ignore_case", true, "/match", "ignoreCase") { out.push(r) }
    if let Some(r) = rewrite::bool_row(params, "negate", false, "/match", "negate") { out.push(r) }
    let grouping = rewrite::logical_grouping(common::param_str(params, "conditions_logical_grouping", ""))?
    if grouping != "" {
        out.push(["conditions_logical_grouping", grouping, "/conditions", "logicalGrouping", "sym"])
    }
    // action.type defaults to None in the schema, so a rule that never sets
    // it matches and changes nothing; it is always written.
    let atype = common::param_str(params, "action_type", "rewrite")
    if atype == "rewrite" { out.push(["action_type", "Rewrite", "/action", "type", "sym"]) }
    else if atype == "none" { out.push(["action_type", "None", "/action", "type", "sym"]) }
    else { return Err("invalid 'action_type' value '" + atype + "' (expected :rewrite or :none)") }
    let value = common::param_str(params, "action_value", "")
    if value != "" { out.push(["action_value", value, "/action", "value", "str"]) }
    if let Some(r) = rewrite::bool_row(params, "replace_server_variable", false, "/action", "replace") { out.push(r) }
    Ok(out)
}

fn validate(params: Value) -> Result[unit, string] {
    rewrite::conditions(params)?
    if !common::want_present(params)? { return Ok(()) }
    if common::param_str(params, "pattern", "") == "" {
        return Err("'pattern' is required when ensure is :present")
    }
    if common::param_str(params, "match_server_variable", "") == "" &&
       common::param_str(params, "filter_by_tags", "") == "" {
        return Err("give either 'match_server_variable' or 'filter_by_tags' so the rule has something to match")
    }
    Ok(())
}

// Whether the live rule already matches everything this step asks for.
fn converged(params: Value, st: string) -> Result[bool, string] {
    if st == "ABSENT" { return Ok(false) }
    let r = json::parse(st)?
    if !rewrite::rows_same(wanted(params)?, r) { return Ok(false) }
    Ok(rewrite::conditions_same(r, rewrite::conditions(params)?))
}

fn check(params: Value) -> Result[CheckResult, string] {
    validate(params)?
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if converged(params, st)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    common::require_rewrite()?
    validate(params)?
    let name = rule_name(params)?
    let scope = common::scope_delegated(params)?
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing outbound rewrite rule " + name)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
            " -Name '.' -AtElement @{{name=" + common::ps_at(common::get_str(json::parse(st)?, "name")) + "}}")?
        return Ok(ApplyResult::Success)
    }
    if converged(params, st)? { return Ok(ApplyResult::Success) }
    let script = ""
    let have = Value::Map(#{})
    let live = name
    if st == "ABSENT" {
        script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
            " -Name '.' -Value @{{name=" + common::ps_q(name) + "}}; "
    } else {
        have = json::parse(st)?
        live = common::get_str(have, "name")
    }
    let rule = rules_filter() + "/rule[@name='" + common::xp(live)? + "']"
    script = script + rewrite::rows_script(scope, rule, wanted(params)?, have)
    let conds = rewrite::conditions(params)?
    if !rewrite::conditions_same(have, conds) {
        script = script + rewrite::conditions_script(scope, rule + "/conditions", conds, st != "ABSENT")
    }
    log::info("writing outbound rewrite rule " + name)
    rewrite::commit(script)?
    Ok(ApplyResult::Success)
}
