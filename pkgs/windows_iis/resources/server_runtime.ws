use value
use common
use section

// ---------------------------------------------------------------------------
// Request-handling limits.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/serverRuntime")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
        ["app_concurrent_request_limit", "appConcurrentRequestLimit", "int"],
        ["frequent_hit_threshold", "frequentHitThreshold", "int"],
        ["frequent_hit_time_period", "frequentHitTimePeriod", "dur"],
        ["max_request_entity_allowed", "maxRequestEntityAllowed", "int"],
        ["upload_read_ahead_size", "uploadReadAheadSize", "int"],
        ["enable_nagling", "enableNagling", "bool"],
        ["alternate_host_name", "alternateHostName", "str"],
        ["authenticated_user_override", "authenticatedUserOverride", "sym"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["authenticated_user_override", "use_authenticated_user", "UseAuthenticatedUser"],
        ["authenticated_user_override", "use_worker_process_user", "UseWorkerProcessUser"],
    ] }

fn spec(params: Value) -> Result[SectionSpec, string] {
    Ok(SectionSpec { filter: section(params)?, scope: scope(params)?, attrs: attrs(), syms: sym_map() })
}

fn check(params: Value) -> Result[CheckResult, string] {
    section::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    section::apply(params, spec(params)?)?
    Ok(ApplyResult::Success)
}
