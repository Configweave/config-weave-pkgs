use value
use common
use section

// ---------------------------------------------------------------------------
// Dynamic IP restrictions. requestIntervalInMilliseconds is a plain number
// of milliseconds rather than a TimeSpan, which is why the duration param
// is converted differently from the ones elsewhere in this package.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/dynamicIpSecurity")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["deny_by_concurrent_requests", "denyByConcurrentRequests.enabled", "bool"],
        ["max_concurrent_requests", "denyByConcurrentRequests.maxConcurrentRequests", "int"],
        ["deny_by_request_rate", "denyByRequestRate.enabled", "bool"],
        ["max_requests", "denyByRequestRate.maxRequests", "int"],
        ["request_interval", "denyByRequestRate.requestIntervalInMilliseconds", "dur_ms"],
        ["enable_logging_only_mode", "enableLoggingOnlyMode", "bool"],
        ["enable_proxy_mode", "enableProxyMode", "bool"],
        ["deny_action", "denyAction", "sym"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["deny_action", "unauthorized", "Unauthorized"],
        ["deny_action", "forbidden", "Forbidden"],
        ["deny_action", "not_found", "NotFound"],
        ["deny_action", "abort", "AbortRequest"],
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
