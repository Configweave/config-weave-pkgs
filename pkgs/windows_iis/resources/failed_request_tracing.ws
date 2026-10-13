use value
use common
use section

// ---------------------------------------------------------------------------
// A site's traceFailedRequestsLogging element; the rules are
// windows_iis.failed_request_tracing_rule.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let site = common::param_str(params, "site", "")
    if site == "" { return Err("missing 'site' parameter") }
    Ok("system.applicationHost/sites/site[@name='" + common::xp(site)? + "']")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "traceFailedRequestsLogging.enabled", "bool"],
        ["directory", "traceFailedRequestsLogging.directory", "str"],
        ["max_log_files", "traceFailedRequestsLogging.maxLogFiles", "int"],
        ["max_log_file_size", "traceFailedRequestsLogging.maxLogFileSizeKB", "int"],
        ["custom_actions_enabled", "traceFailedRequestsLogging.customActionsEnabled", "bool"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

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
