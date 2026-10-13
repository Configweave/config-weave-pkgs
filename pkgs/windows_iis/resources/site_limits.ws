use value
use common
use section

// ---------------------------------------------------------------------------
// A site's limits element. system.applicationHost is never delegated, so
// the site is named in the filter rather than in a -Location.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let site = common::param_str(params, "site", "")
    if site == "" { return Err("missing 'site' parameter") }
    Ok("system.applicationHost/sites/site[@name='" + common::xp(site)? + "']")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["max_bandwidth", "limits.maxBandwidth", "int"],
        ["max_connections", "limits.maxConnections", "int"],
        ["connection_timeout", "limits.connectionTimeout", "dur"],
        ["max_url_segments", "limits.maxUrlSegments", "int"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

fn spec(params: Value) -> Result[SectionSpec, string] {
    Ok(SectionSpec { filter: section(params)?, scope: scope(params)?, attrs: attrs(), syms: sym_map(), extra: [] })
}

fn check(params: Value) -> Result[CheckResult, string] {
    section::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    section::apply(params, spec(params)?)?
    Ok(ApplyResult::Success)
}
