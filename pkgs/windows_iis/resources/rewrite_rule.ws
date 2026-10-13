use value
use json
use log
use common
use rewrite

// ---------------------------------------------------------------------------
// An inbound URL Rewrite rule.
//
// A rule is the rule element plus its match, conditions, serverVariables and
// action children. An existing rule is patched where it stands (see
// lib/rewrite.ws), so it keeps its place in the rule set — rules are
// evaluated in order — and a new rule is added at the end.
//
// Conditions are "input|pattern" strings with an optional last field of
// comma-separated flags, because a list of records is not expressible as a
// param type: "{HTTPS}|^OFF$" or "{REQUEST_FILENAME}||isFile,negate". Server
// variables are "NAME|value" with an optional last field of true or false
// for replace: "HTTP_X_ORIGINAL_HOST|{HTTP_HOST}".
// ---------------------------------------------------------------------------

fn rules_filter() -> string { "system.webServer/rewrite/rules" }

fn rule_name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    if n == "" { return Err("missing 'name' parameter") }
    Ok(n)
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

// [name, value, replace] from "NAME|value" or "NAME|value|true|false". The
// last field is replace only when there are at least three fields and it is
// exactly true or false, so a value holding "|" survives.
fn parse_server_variable(spec: string) -> Result[List[string], string] {
    let parts = spec.split("|")
    if parts.len() < 2 || parts.get(0).unwrap_or("") == "" {
        return Err("server variable '" + spec + "' must be written \"NAME|value\" or \"NAME|value|false\"")
    }
    let end = parts.len()
    let replace = "true"
    let last = parts.get(parts.len() - 1).unwrap_or("").to_lower()
    if parts.len() >= 3 && (last == "true" || last == "false") {
        replace = last
        end = parts.len() - 1
    }
    let value: List[string] = []
    let i = 1
    while i < end { value.push(parts.get(i).unwrap_or("")); i = i + 1 }
    Ok([parts.get(0).unwrap_or(""), value.join("|"), replace])
}

fn server_variables(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    for spec in common::param_list(params, "server_variables") { out.push(parse_server_variable(spec)?) }
    Ok(out)
}

fn server_variables_same(have: Value, want: List[List[string]]) -> bool {
    let h = rewrite::items(have.get("server_variables"))
    if h.len() != want.len() { return false }
    let i = 0
    while i < want.len() {
        let c = h.get(i).unwrap_or(Value::Null)
        let w = want.get(i).unwrap_or([])
        if common::get_str(c, "name").to_lower() != w.get(0).unwrap_or("").to_lower() { return false }
        if common::get_str(c, "value") != w.get(1).unwrap_or("") { return false }
        if common::get_str(c, "replace").to_lower() != w.get(2).unwrap_or("") { return false }
        i = i + 1
    }
    true
}

// 'ABSENT', or the rule flattened to the shape wanted() compares against;
// "name" is the rule's name as IIS stores it. A missing rewrite section
// reads as ABSENT so a check on a machine without the module reports drift
// rather than erroring.
fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$r = @(); try {{ $r = @(Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(rules_filter() + "/rule") + " | Where-Object {{ [string]$_.name -eq " +
        common::ps_q(rule_name(params)?) + " }}) }} catch {{ }}; " +
        "if ($r.Count -eq 0) {{ 'ABSENT' }} else {{ $x = $r[0]; " +
        "[pscustomobject]@{{ name = [string]$x.name; " +
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
        "conditions = " + rewrite::read_conditions("$x.conditions.Collection") + "; " +
        "server_variables = @($x.serverVariables.Collection | ForEach-Object {{ [pscustomobject]@{{ " +
        "name = [string]$_.name; value = [string]$_.value; replace = CwV($_.replace) }} }}) " +
        "}} | ConvertTo-Json -Compress -Depth 5 }}")
}

// [probe key, desired text, element suffix, IIS attribute, kind] for
// everything the step named.
fn wanted(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    if let Some(r) = rewrite::bool_row(params, "enabled", true, "", "enabled") { out.push(r) }
    if let Some(r) = rewrite::bool_row(params, "stop_processing", false, "", "stopProcessing") { out.push(r) }
    let syntax = rewrite::pattern_syntax(common::param_str(params, "pattern_syntax", ""))?
    if syntax != "" { out.push(["pattern_syntax", syntax, "", "patternSyntax", "sym"]) }
    let url = common::param_str(params, "match_url", "")
    if url != "" { out.push(["match_url", url, "/match", "url", "str"]) }
    if let Some(r) = rewrite::bool_row(params, "ignore_case", true, "/match", "ignoreCase") { out.push(r) }
    if let Some(r) = rewrite::bool_row(params, "negate", false, "/match", "negate") { out.push(r) }
    let grouping = rewrite::logical_grouping(common::param_str(params, "conditions_logical_grouping", ""))?
    if grouping != "" {
        out.push(["conditions_logical_grouping", grouping, "/conditions", "logicalGrouping", "sym"])
    }
    if let Some(r) = rewrite::bool_row(params, "conditions_track_all_captures", false, "/conditions", "trackAllCaptures") { out.push(r) }
    let atype = action_type(common::param_str(params, "action_type", ""))?
    if atype != "" { out.push(["action_type", atype, "/action", "type", "sym"]) }
    let aurl = common::param_str(params, "action_url", "")
    if aurl != "" { out.push(["action_url", aurl, "/action", "url", "str"]) }
    if let Some(r) = rewrite::bool_row(params, "append_query_string", true, "/action", "appendQueryString") { out.push(r) }
    if let Some(r) = rewrite::bool_row(params, "log_rewritten_url", true, "/action", "logRewrittenUrl") { out.push(r) }
    let rtype = redirect_type(common::param_str(params, "redirect_type", ""))?
    if rtype != "" { out.push(["redirect_type", rtype, "/action", "redirectType", "sym"]) }
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

fn validate(params: Value) -> Result[unit, string] {
    if common::want_present(params)? && common::param_str(params, "match_url", "") == "" {
        return Err("'match_url' is required when ensure is :present")
    }
    rewrite::conditions(params)?
    server_variables(params)?
    Ok(())
}

// Whether the live rule already matches everything this step asks for.
fn converged(params: Value, st: string) -> Result[bool, string] {
    if st == "ABSENT" { return Ok(false) }
    let r = json::parse(st)?
    if !rewrite::rows_same(wanted(params)?, r) { return Ok(false) }
    if !rewrite::conditions_same(r, rewrite::conditions(params)?) { return Ok(false) }
    Ok(server_variables_same(r, server_variables(params)?))
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
        log::info("removing rewrite rule " + name)
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
    let vars = server_variables(params)?
    if !server_variables_same(have, vars) {
        if st != "ABSENT" {
            script = script + "Remove-WebConfigurationProperty" + scope + " -Filter " +
                common::ps_q(rule + "/serverVariables") + " -Name '.'; "
        }
        for v in vars {
            script = script + "Add-WebConfigurationProperty" + scope + " -Filter " +
                common::ps_q(rule + "/serverVariables") + " -Name '.' -Value @{{name=" +
                common::ps_q(v.get(0).unwrap_or("")) + "; value=" + common::ps_q(v.get(1).unwrap_or("")) +
                "; replace=" + (if v.get(2).unwrap_or("") == "true" { "$true" } else { "$false" }) + "}}; "
        }
    }
    log::info("writing rewrite rule " + name)
    rewrite::commit(script)?
    Ok(ApplyResult::Success)
}
