use value
use common
use section

// ---------------------------------------------------------------------------
// Anonymous authentication. An empty userName is meaningful to IIS — it
// selects the application pool identity — but an empty `username` param is
// this package's "leave it alone", so the pool identity is chosen with
// use_app_pool_identity = true, which writes userName and password as "".
// The password is a secret: it is passed through the environment and masked
// in the log.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/authentication/anonymousAuthentication")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
        ["username", "userName", "str"],
        ["password", "password", "secret"],
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
    let extra: List[List[string]] = []
    if common::param_bool(params, "use_app_pool_identity", false) {
        if common::param_str(params, "username", "") != "" || common::param_str(params, "password", "") != "" {
            return Err("use_app_pool_identity = true cannot be combined with 'username' or 'password'")
        }
        extra = [["username", "userName", "str", ""], ["password", "password", "secret", ""]]
    }
    Ok(SectionSpec { filter: section(params)?, scope: scope(params)?, attrs: attrs(), syms: sym_map(), extra: extra })
}

fn check(params: Value) -> Result[CheckResult, string] {
    section::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    section::apply(params, spec(params)?)?
    Ok(ApplyResult::Success)
}
