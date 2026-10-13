use value
use json
use log
use common
use rewrite

// ---------------------------------------------------------------------------
// An inbound URL Rewrite rule.
//
// A rule is not one element but four — the rule, its match, its conditions
// and its action — so it is written whole rather than attribute by
// attribute: the rule with this name is removed and rebuilt. That keeps the
// resource honest about what it owns (everything under the rule) and makes
// the ordering explicit, since a rebuilt rule lands at the end of the rule
// set and rules are evaluated in order.
//
// Conditions are "input|pattern" strings with an optional third field of
// comma-separated flags, because a list of records is not expressible as a
// param type: "{HTTPS}|^OFF$" or "{REQUEST_FILENAME}||isFile,negate".
// ---------------------------------------------------------------------------

fn rules_filter() -> string { "system.webServer/rewrite/rules" }

fn rule_name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    if n == "" { return Err("missing 'name' parameter") }
    Ok(n)
}

fn rule_filter(params: Value) -> Result[string, string] {
    Ok(rules_filter() + "/rule[@name='" + common::xp(rule_name(params)?)? + "']")
}

fn action_type(v: string) -> Result[string, string] {
    if v == "" { return Ok("") }
    if v == "rewrite" { return Ok("Rewrite") }
    if v == "redirect" { return Ok("Redirect") }
    if v == "custom_response" { return Ok("CustomResponse") }
    if v == "abort_request" { return Ok("AbortRequest") }
    if v == "none" { return Ok("None") }
    Err("invalid 'action_type' value '" + v + "'")
}

fn redirect_type(v: string) -> Result[string, string] {
    if v == "" { return Ok("") }
    if v == "permanent" { return Ok("Permanent") }
    if v == "found" { return Ok("Found") }
    if v == "see_other" { return Ok("SeeOther") }
    if v == "temporary" { return Ok("Temporary") }
    Err("invalid 'redirect_type' value '" + v + "'")
}

// 'ABSENT', or the rule flattened to the shape conditions_text and the param
// accessors compare against. A missing rewrite section reads as ABSENT so a
// check on a machine without the module reports drift rather than erroring.
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
        "pattern_syntax = CwV($x.patternSyntax); match_url = CwV($x.match.url); " +
        "ignore_case = CwV($x.match.ignoreCase); negate = CwV($x.match.negate); " +
        "conditions_logical_grouping = CwV($x.conditions.logicalGrouping); " +
        "conditions_track_all_captures = CwV($x.conditions.trackAllCaptures); " +
        "action_type = CwV($x.action.type); action_url = CwV($x.action.url); " +
        "append_query_string = CwV($x.action.appendQueryString); " +
        "log_rewritten_url = CwV($x.action.logRewrittenUrl); " +
        "redirect_type = CwV($x.action.redirectType); " +
        "status_code = CwV($x.action.statusCode); sub_status_code = CwV($x.action.subStatusCode); " +
        "status_reason = CwV($x.action.statusReason); " +
        "status_description = CwV($x.action.statusDescription); " +
        "conditions = ($conds -join ';;') }} | ConvertTo-Json -Compress }}")
}

fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
}

// [key in the probe, desired text] for everything the step named. `element`
// says which of the four elements the attribute belongs to and `attribute`
// its IIS name; both are only needed by apply.
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
    let url = common::param_str(params, "match_url", "")
    if url != "" { out.push(["match_url", url, "/match", "url", "str"]) }
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
    if common::has(params, "conditions_track_all_captures") {
        out.push(["conditions_track_all_captures",
            if common::param_bool(params, "conditions_track_all_captures", false) { "true" } else { "false" },
            "/conditions", "trackAllCaptures", "bool"])
    }
    let atype = action_type(common::param_str(params, "action_type", ""))?
    if atype != "" { out.push(["action_type", atype, "/action", "type", "str"]) }
    let aurl = common::param_str(params, "action_url", "")
    if aurl != "" { out.push(["action_url", aurl, "/action", "url", "str"]) }
    if common::has(params, "append_query_string") {
        out.push(["append_query_string",
            if common::param_bool(params, "append_query_string", true) { "true" } else { "false" },
            "/action", "appendQueryString", "bool"])
    }
    if common::has(params, "log_rewritten_url") {
        out.push(["log_rewritten_url",
            if common::param_bool(params, "log_rewritten_url", true) { "true" } else { "false" },
            "/action", "logRewrittenUrl", "bool"])
    }
    let rtype = redirect_type(common::param_str(params, "redirect_type", ""))?
    if rtype != "" { out.push(["redirect_type", rtype, "/action", "redirectType", "str"]) }
    if common::has(params, "status_code") {
        out.push(["status_code", common::itoa(common::param_int(params, "status_code", 0)),
            "/action", "statusCode", "int"])
    }
    if common::has(params, "sub_status_code") {
        out.push(["sub_status_code", common::itoa(common::param_int(params, "sub_status_code", 0)),
            "/action", "subStatusCode", "int"])
    }
    let reason = common::param_str(params, "status_reason", "")
    if reason != "" { out.push(["status_reason", reason, "/action", "statusReason", "str"]) }
    let desc = common::param_str(params, "status_description", "")
    if desc != "" { out.push(["status_description", desc, "/action", "statusDescription", "str"]) }
    Ok(out)
}

// Whether the live rule already matches everything this step asks for. apply
// uses it to avoid rebuilding — and so reordering — a converged rule.
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
        log::info("removing rewrite rule " + name)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
            " -Name '.' -AtElement @{{name=" + common::ps_q(name) + "}}")?
        return Ok(ApplyResult::Success)
    }
    if common::param_str(params, "match_url", "") == "" {
        return Err("'match_url' is required when ensure is :present")
    }
    // Nothing differs: return without touching anything. These resources
    // rebuild the element rather than patching it, and rebuilding moves it to
    // the end of its collection — rewrite rules are evaluated in order, so a converged
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
    log::info("writing rewrite rule " + name)
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
