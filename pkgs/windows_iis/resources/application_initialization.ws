use value
use common
use section

// ---------------------------------------------------------------------------
// Application warm-up; the pages themselves are
// windows_iis.application_initialization_page.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/applicationInitialization")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["do_app_init_after_restart", "doAppInitAfterRestart", "bool"],
        ["remap_managed_requests_to", "remapManagedRequestsTo", "str"],
        ["skip_managed_modules", "skipManagedModules", "bool"],
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
