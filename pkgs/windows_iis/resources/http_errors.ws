use value
use common
use section

// ---------------------------------------------------------------------------
// The custom error policy; the per-status pages are windows_iis.http_error.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/httpErrors")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["error_mode", "errorMode", "sym"],
        ["existing_response", "existingResponse", "sym"],
        ["default_path", "defaultPath", "str"],
        ["default_response_mode", "defaultResponseMode", "sym"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["error_mode", "detailed", "Detailed"],
        ["error_mode", "detailed_local_only", "DetailedLocalOnly"],
        ["error_mode", "custom", "Custom"],
        ["existing_response", "auto", "Auto"],
        ["existing_response", "replace", "Replace"],
        ["existing_response", "pass_through", "PassThrough"],
        ["default_response_mode", "file", "File"],
        ["default_response_mode", "execute_url", "ExecuteURL"],
        ["default_response_mode", "redirect", "Redirect"],
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
