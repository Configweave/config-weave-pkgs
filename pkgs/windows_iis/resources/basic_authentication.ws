use value
use common
use section

// ---------------------------------------------------------------------------
// Basic authentication.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/authentication/basicAuthentication")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
        ["realm", "realm", "str"],
        ["default_logon_domain", "defaultLogonDomain", "str"],
        ["logon_method", "logonMethod", "sym"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["logon_method", "interactive", "Interactive"],
        ["logon_method", "batch", "Batch"],
        ["logon_method", "network", "Network"],
        ["logon_method", "cleartext", "ClearText"],
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
