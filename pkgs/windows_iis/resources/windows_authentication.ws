use value
use common
use section

// ---------------------------------------------------------------------------
// Windows authentication. `providers` is an ordered collection rather than
// an attribute, so it replaces the inherited list instead of adding to it —
// which is what the preference order needs.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/authentication/windowsAuthentication")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
        ["providers", "providers", "vlist"],
        ["auth_persist_single_request", "authPersistSingleRequest", "bool"],
        ["auth_persist_non_ntlm", "authPersistNonNTLM", "bool"],
        ["use_kernel_mode", "useKernelMode", "bool"],
        ["use_app_pool_credentials", "useAppPoolCredentials", "bool"],
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
