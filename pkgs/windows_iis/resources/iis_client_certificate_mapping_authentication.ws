use value
use common
use section

// ---------------------------------------------------------------------------
// IIS's own client certificate mapping. The mapping tables themselves are
// collections of credentials; reach them with config_collection_element.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/authentication/iisClientCertificateMappingAuthentication")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
        ["one_to_one_enabled", "oneToOneCertificateMappingsEnabled", "bool"],
        ["many_to_one_enabled", "manyToOneCertificateMappingsEnabled", "bool"],
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
