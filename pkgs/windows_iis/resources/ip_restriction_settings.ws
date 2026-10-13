use value
use common
use section

// ---------------------------------------------------------------------------
// The policy half of IP and domain restrictions; the entries are
// windows_iis.ip_restriction.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/ipSecurity")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["allow_unlisted", "allowUnlisted", "bool"],
        ["enable_reverse_dns", "enableReverseDns", "bool"],
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
