use value
use common
use section

// ---------------------------------------------------------------------------
// Classic ASP.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/asp")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enable_parent_paths", "enableParentPaths", "bool"],
        ["buffering_on", "bufferingOn", "bool"],
        ["script_timeout", "limits.scriptTimeout", "dur"],
        ["script_error_sent_to_browser", "scriptErrorSentToBrowser", "bool"],
        ["script_error_message", "scriptErrorMessage", "str"],
        ["code_page", "codePage", "int"],
        ["lcid", "lcid", "int"],
        ["script_language", "scriptLanguage", "str"],
        ["allow_session_state", "session.allowSessionState", "bool"],
        ["session_timeout", "session.timeout", "dur"],
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
