use value
use common
use section

// ---------------------------------------------------------------------------
// Anonymous authentication. An empty userName is meaningful to IIS — it
// selects the application pool identity — but it is also this package's
// "leave it alone", so set the pool identity with config_property when you
// need to move away from a named account.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/authentication/anonymousAuthentication")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
        ["username", "userName", "str"],
        ["password", "password", "str"],
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
    Ok(SectionSpec { filter: section(params)?, scope: scope(params)?, attrs: attrs(), syms: sym_map() })
}

fn check(params: Value) -> Result[CheckResult, string] {
    section::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    section::apply(params, spec(params)?)?
    Ok(ApplyResult::Success)
}
