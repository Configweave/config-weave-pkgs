use value
use json
use log
use common

// ---------------------------------------------------------------------------
// A failed request tracing rule: which requests get a trace log, and which
// providers are asked to contribute to it.
//
// The rule is an element with a failureDefinitions child and a traceAreas
// collection. Drift is patched in place — the failureDefinitions attributes
// that differ are set, and a changed provider list replaces the traceAreas
// collection — so the rule keeps its position: failed-request tracing rules
// are evaluated in order.
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

// One "provider|areas|verbosity" entry per provider, lowercased, with the
// areas as a sorted set — `areas` is a flags attribute, which IIS renders in
// its own order and spacing — and the entries themselves sorted, since
// traceAreas is keyed by provider and its order carries no meaning.
fn provider_entry(provider: string, areas: string, level: string) -> string {
    let set = common::flag_set(areas)
    set.sort()
    provider.to_lower() + "|" + set.join(",") + "|" + level.to_lower()
}

fn providers_text(params: Value) -> Result[string, string] {
    let out: List[string] = []
    for spec in common::param_list(params, "providers") {
        let p = parse_provider(spec)?
        out.push(provider_entry(p.get(0).unwrap_or(""), p.get(1).unwrap_or(""), p.get(2).unwrap_or("")))
    }
    out.sort()
    Ok(out.join(";;"))
}

fn live_providers(r: Value) -> string {
    let out: List[string] = []
    for e in common::get_str(r, "providers").split(";;") {
        if e == "" { continue }
        let p = e.split("|")
        out.push(provider_entry(p.get(0).unwrap_or(""), p.get(1).unwrap_or(""), p.get(2).unwrap_or("")))
    }
    out.sort()
    out.join(";;")
}

// 'ABSENT', or the rule flattened for comparison; "path" is the content path
// as IIS stores it, matched case-insensitively as IIS matches it.
fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$r = @(); try {{ $r = @(Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(rules_filter() + "/add") + " | Where-Object {{ [string]$_.path -eq " +
        common::ps_q(content_path(params)?) + " }}) }} catch {{ }}; " +
        "if ($r.Count -eq 0) {{ 'ABSENT' }} else {{ $x = $r[0]; " +
        "$areas = @($x.traceAreas.Collection | ForEach-Object {{ " +
        "([string]$_.provider + '|' + [string]$_.areas + '|' + [string]$_.verbosity) }}); " +
        "[pscustomobject]@{{ path = [string]$x.path; status_codes = CwV($x.failureDefinitions.statusCodes); " +
        "time_taken = CwV($x.failureDefinitions.timeTaken); " +
        "verbosity = CwV($x.failureDefinitions.verbosity); " +
        "providers = ($areas -join ';;') }} | ConvertTo-Json -Compress }}")
}

fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
}

// [attribute, PowerShell literal] for each failureDefinitions attribute that
// differs from the step.
fn definition_drift(params: Value, r: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    let codes = common::param_str(params, "status_codes", "")
    if codes != "" && !same(common::get_str(r, "status_codes"), codes) { out.push(["statusCodes", common::ps_q(codes)]) }
    if common::has(params, "time_taken") {
        let t = common::hms(common::param_int(params, "time_taken", 0))
        if common::get_str(r, "time_taken") != t { out.push(["timeTaken", common::ps_q(t)]) }
    }
    let level = verbosity(common::param_str(params, "verbosity", ""))?
    if level != "" && !same(common::get_str(r, "verbosity"), level) { out.push(["verbosity", common::ps_q(level)]) }
    Ok(out)
}

// Whether the live rule already matches what this step asks for.
fn converged(params: Value, st: string) -> Result[bool, string] {
    if st == "ABSENT" { return Ok(false) }
    let r = json::parse(st)?
    if !definition_drift(params, r)?.is_empty() { return Ok(false) }
    Ok(live_providers(r) == providers_text(params)?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if converged(params, st)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let path = content_path(params)?
    let scope = common::scope_delegated(params)?
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing failed request tracing rule for " + path)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
            " -Name '.' -AtElement @{{path=" + common::ps_q(common::get_str(json::parse(st)?, "path")) + "}}")?
        return Ok(ApplyResult::Success)
    }
    if converged(params, st)? { return Ok(ApplyResult::Success) }
    let script = ""
    let live = path
    let r = Value::Map(#{})
    let have_providers = ""
    if st == "ABSENT" {
        script = script + "Add-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(rules_filter()) +
            " -Name '.' -Value @{{path=" + common::ps_q(path) + "}}; "
    } else {
        r = json::parse(st)?
        live = common::get_str(r, "path")
        have_providers = live_providers(r)
    }
    let rule = rules_filter() + "/add[@path='" + common::xp(live)? + "']"
    for d in definition_drift(params, r)? {
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " +
            common::ps_q(rule + "/failureDefinitions") + " -Name " + common::ps_q(d.get(0).unwrap_or("")) +
            " -Value " + d.get(1).unwrap_or("") + "; "
    }
    if have_providers != providers_text(params)? {
        // Removing every entry writes <clear/>, so no inherited trace area
        // survives alongside the ones this step names.
        if st != "ABSENT" {
            script = script + "Remove-WebConfigurationProperty" + scope + " -Filter " +
                common::ps_q(rule + "/traceAreas") + " -Name '.'; "
        }
        for spec in common::param_list(params, "providers") {
            let p = parse_provider(spec)?
            script = script + "Add-WebConfigurationProperty" + scope + " -Filter " +
                common::ps_q(rule + "/traceAreas") + " -Name '.' -Value @{{provider=" +
                common::ps_q(p.get(0).unwrap_or("")) + "; areas=" + common::ps_q(p.get(1).unwrap_or("")) +
                "; verbosity=" + common::ps_q(p.get(2).unwrap_or("")) + "}}; "
        }
    }
    log::info("writing failed request tracing rule for " + path)
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
