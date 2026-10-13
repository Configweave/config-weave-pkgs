use value
use common
use section

// ---------------------------------------------------------------------------
// The limits half of request filtering; the lists are
// windows_iis.request_filtering_rule.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/requestFiltering")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["allow_double_escaping", "allowDoubleEscaping", "bool"],
        ["allow_high_bit_characters", "allowHighBitCharacters", "bool"],
        ["allow_unlisted_file_extensions", "fileExtensions.allowUnlisted", "bool"],
        ["allow_unlisted_verbs", "verbs.allowUnlisted", "bool"],
        ["max_allowed_content_length", "requestLimits.maxAllowedContentLength", "int"],
        ["max_url", "requestLimits.maxUrl", "int"],
        ["max_query_string", "requestLimits.maxQueryString", "int"],
        ["remove_server_header", "removeServerHeader", "bool"],
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
