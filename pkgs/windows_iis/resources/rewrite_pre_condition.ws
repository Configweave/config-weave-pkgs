use value
use json
use log
use common
use rewrite

// ---------------------------------------------------------------------------
// An outbound rewrite pre-condition: the gate that keeps an outbound rule off
// responses it has no business rewriting.
//
// Patched in place like the rules (see lib/rewrite.ws); the pre-condition
// element is itself the collection of its conditions.
// ---------------------------------------------------------------------------

fn pre_filter() -> string { "system.webServer/rewrite/outboundRules/preConditions" }

fn pre_name(params: Value) -> Result[string, string] {
    let n = common::param_str(params, "name", "")
    if n == "" { return Err("missing 'name' parameter") }
    Ok(n)
}

fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$r = @(); try {{ $r = @(Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(pre_filter() + "/preCondition") + " | Where-Object {{ [string]$_.name -eq " +
        common::ps_q(pre_name(params)?) + " }}) }} catch {{ }}; " +
        "if ($r.Count -eq 0) {{ 'ABSENT' }} else {{ $x = $r[0]; " +
        "[pscustomobject]@{{ name = [string]$x.name; logical_grouping = CwV($x.logicalGrouping); " +
        "pattern_syntax = CwV($x.patternSyntax); " +
        "conditions = " + rewrite::read_conditions("$x.Collection") +
        " }} | ConvertTo-Json -Compress -Depth 5 }}")
}

fn wanted(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    let grouping = rewrite::logical_grouping(common::param_str(params, "logical_grouping", ""))?
    if grouping != "" { out.push(["logical_grouping", grouping, "", "logicalGrouping", "sym"]) }
    let syntax = rewrite::pattern_syntax(common::param_str(params, "pattern_syntax", ""))?
    if syntax != "" { out.push(["pattern_syntax", syntax, "", "patternSyntax", "sym"]) }
    Ok(out)
}

// Whether the live pre-condition already matches what this step asks for.
fn converged(params: Value, st: string) -> Result[bool, string] {
    if st == "ABSENT" { return Ok(false) }
    let r = json::parse(st)?
    if !rewrite::rows_same(wanted(params)?, r) { return Ok(false) }
    Ok(rewrite::conditions_same(r, rewrite::conditions(params)?))
}

fn check(params: Value) -> Result[CheckResult, string] {
    rewrite::conditions(params)?
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
    let name = pre_name(params)?
    let scope = common::scope_delegated(params)?
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing rewrite pre-condition " + name)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(pre_filter()) +
            " -Name '.' -AtElement @{{name=" + common::ps_q(common::get_str(json::parse(st)?, "name")) + "}}")?
        return Ok(ApplyResult::Success)
    }
    if converged(params, st)? { return Ok(ApplyResult::Success) }
    let script = ""
    let have = Value::Map(#{})
    let live = name
    if st == "ABSENT" {
        script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(pre_filter()) +
            " -Name '.' -Value @{{name=" + common::ps_q(name) + "}}; "
    } else {
        have = json::parse(st)?
        live = common::get_str(have, "name")
    }
    let elem = pre_filter() + "/preCondition[@name='" + common::xp(live)? + "']"
    script = script + rewrite::rows_script(scope, elem, wanted(params)?, have)
    let conds = rewrite::conditions(params)?
    if !rewrite::conditions_same(have, conds) {
        script = script + rewrite::conditions_script(scope, elem, conds, st != "ABSENT")
    }
    log::info("writing rewrite pre-condition " + name)
    rewrite::commit(script)?
    Ok(ApplyResult::Success)
}
