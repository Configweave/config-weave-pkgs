use value
use json
use log
use common

// ---------------------------------------------------------------------------
// A failed request tracing rule: which requests get a trace log, and which
// providers are asked to contribute to it.
//
// The rule is an element with a failureDefinitions child and a traceAreas
// collection, so — as with the rewrite rules — it is written whole rather
// than patched.
//
// Providers are "Provider:areas:verbosity" strings because a list of records
// is not expressible as a param type:
// "WWW Server:Authentication,Security:Verbose".
// ---------------------------------------------------------------------------

fn rules_filter() -> string { "system.webServer/tracing/traceFailedRequests" }

fn content_path(params: Value) -> Result[string, string] {
    let p = common::param_str(params, "content_path", "")
    if p == "" { return Err("missing 'content_path' parameter") }
    Ok(p)
}

fn rule_filter(params: Value) -> Result[string, string] {
    Ok(rules_filter() + "/add[@path='" + common::xp(content_path(params)?)? + "']")
}

fn verbosity(v: string) -> Result[string, string] {
    if v == "" { return Ok("") }
    if v == "ignore" { return Ok("Ignore") }
    if v == "critical_error" { return Ok("CriticalError") }
    if v == "error" { return Ok("Error") }
    if v == "warning" { return Ok("Warning") }
    Err("invalid verbosity '" + v + "'")
}

// traceAreas/@verbosity is NOT the same enum as failureDefinitions/@verbosity:
// it has General where the other has Ignore, and it has the two levels the
// other lacks. Validating here turns a raw IIS schema error at apply time into
// a message that says what the legal values are.
fn trace_verbosity(v: string) -> Result[string, string] {
    for legal in ["General", "CriticalError", "Error", "Warning", "Information", "Verbose"] {
        if legal.to_lower() == v.to_lower() { return Ok(legal) }
    }
    Err("invalid trace area verbosity '" + v + "' (expected General, CriticalError, Error, " +
        "Warning, Information or Verbose)")
}

// [provider, areas, verbosity] from "Provider:areas:verbosity". The provider
// name itself never contains a colon, and neither does an area list, so the
// split is unambiguous.
fn parse_provider(spec: string) -> Result[List[string], string] {
    let parts = spec.split(":")
    if parts.len() < 2 {
        return Err("provider '" + spec + "' must be written \"Provider:areas\" or \"Provider:areas:verbosity\"")
    }
    let level = if parts.len() > 2 { trace_verbosity(parts.get(2).unwrap_or(""))? } else { "Verbose" }
    Ok([parts.get(0).unwrap_or(""), parts.get(1).unwrap_or(""), level])
}

fn providers_text(params: Value) -> Result[string, string] {
    let out: List[string] = []
    for spec in common::param_list(params, "providers") {
        let p = parse_provider(spec)?
        // Spaces stripped from the area list on both sides: `areas` is a flags
        // attribute and IIS renders it "Authentication, Security".
        out.push(p.get(0).unwrap_or("").to_lower() + "|" +
            p.get(1).unwrap_or("").to_lower().replace(" ", "") +
            "|" + p.get(2).unwrap_or("").to_lower())
    }
    Ok(out.join(";;"))
}

fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$r = @(); try {{ $r = @(Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(rules_filter() + "/add") + " | Where-Object {{ [string]$_.path -eq " +
        common::ps_q(content_path(params)?) + " }}) }} catch {{ }}; " +
        "if ($r.Count -eq 0) {{ 'ABSENT' }} else {{ $x = $r[0]; " +
        "$areas = @($x.traceAreas.Collection | ForEach-Object {{ " +
        "(([string]$_.provider).ToLower() + '|' + " +
        "(([string]$_.areas).ToLower() -replace ' ', '') + '|' + " +
        "([string]$_.verbosity).ToLower()) }}); " +
        "[pscustomobject]@{{ status_codes = CwV($x.failureDefinitions.statusCodes); " +
        "time_taken = CwV($x.failureDefinitions.timeTaken); " +
        "verbosity = CwV($x.failureDefinitions.verbosity); " +
        "providers = ($areas -join ';;') }} | ConvertTo-Json -Compress }}")
}

fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
}

// Whether the live rule already matches what this step asks for.
fn converged(params: Value) -> Result[bool, string] {
    let st = probe(params)?
    if st == "ABSENT" { return Ok(false) }
    let r = json::parse(st)?
    let codes = common::param_str(params, "status_codes", "")
    if codes != "" && !same(common::get_str(r, "status_codes"), codes) { return Ok(false) }
    if common::has(params, "time_taken") && common::get_str(r, "time_taken") != common::hms(common::param_int(params, "time_taken", 0)) {
        return Ok(false)
    }
    let level = verbosity(common::param_str(params, "verbosity", ""))?
    if level != "" && !same(common::get_str(r, "verbosity"), level) { return Ok(false) }
    Ok(common::get_str(r, "providers") == providers_text(params)?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let r = json::parse(st)?
    let codes = common::param_str(params, "status_codes", "")
    if codes != "" && !same(common::get_str(r, "status_codes"), codes) { return Ok(CheckResult::NotConfigured) }
    if common::has(params, "time_taken") {
        if common::get_str(r, "time_taken") != common::hms(common::param_int(params, "time_taken", 0)) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    let level = verbosity(common::param_str(params, "verbosity", ""))?
    if level != "" && !same(common::get_str(r, "verbosity"), level) { return Ok(CheckResult::NotConfigured) }
    if common::get_str(r, "providers") != providers_text(params)? { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let path = content_path(params)?
    let scope = common::scope_delegated(params)?
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing failed request tracing rule for " + path)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
            " -Name '.' -AtElement @{{path=" + common::ps_q(path) + "}}")?
        return Ok(ApplyResult::Success)
    }
    // A converged rule is left strictly alone: rebuilding it would move it to
    // the end of the collection, and failed-request tracing rules are
    // evaluated in order.
    if converged(params)? { return Ok(ApplyResult::Success) }
    let script = ""
    if st != "ABSENT" {
        script = script + "Remove-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rules_filter()) + " -Name '.' -AtElement @{{path=" + common::ps_q(path) + "}}; "
    }
    script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
        " -Name '.' -Value @{{path=" + common::ps_q(path) + "}}; "
    let rule = rule_filter(params)?
    let codes = common::param_str(params, "status_codes", "")
    if codes != "" {
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rule + "/failureDefinitions") + " -Name 'statusCodes' -Value " + common::ps_q(codes) + "; "
    }
    if common::has(params, "time_taken") {
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rule + "/failureDefinitions") + " -Name 'timeTaken' -Value " +
            common::ps_q(common::hms(common::param_int(params, "time_taken", 0))) + "; "
    }
    let level = verbosity(common::param_str(params, "verbosity", ""))?
    if level != "" {
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rule + "/failureDefinitions") + " -Name 'verbosity' -Value " + common::ps_q(level) + "; "
    }
    for spec in common::param_list(params, "providers") {
        let p = parse_provider(spec)?
        script = script + "Add-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rule + "/traceAreas") + " -Name '.' -Value @{{provider=" +
            common::ps_q(p.get(0).unwrap_or("")) + "; areas=" + common::ps_q(p.get(1).unwrap_or("")) +
            "; verbosity=" + common::ps_q(p.get(2).unwrap_or("")) + "}}; "
    }
    log::info("writing failed request tracing rule for " + path)
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
