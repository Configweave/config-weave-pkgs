use value
use common
use section

// ---------------------------------------------------------------------------
// Whole-directory HTTP redirection.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/httpRedirect")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
        ["destination", "destination", "str"],
        ["exact_destination", "exactDestination", "bool"],
        ["child_only", "childOnly", "bool"],
        ["http_response_status", "httpResponseStatus", "sym"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["http_response_status", "permanent", "Permanent"],
        ["http_response_status", "found", "Found"],
        ["http_response_status", "temporary", "Temporary"],
        ["http_response_status", "permanent_redirect", "PermRedirect"],
    ] }

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
