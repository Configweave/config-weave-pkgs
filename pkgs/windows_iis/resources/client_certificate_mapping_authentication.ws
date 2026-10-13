use value
use log
use common
use section

// ---------------------------------------------------------------------------
// Active Directory client certificate mapping.
//
// IIS documents this section's `enabled` as taking effect only when set
// through IIS Manager — any other route needs the web server restarted —
// so a change here restarts W3SVC rather than reporting a success that
// has not actually taken hold.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/authentication/clientCertificateMappingAuthentication")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

// Run after apply changes something.
fn postcondition(params: Value) -> Result[unit, string] {
    log::info("restarting W3SVC so the mapping takes effect")
    common::ps_run("Restart-Service -Name W3SVC -Force")
}

fn spec(params: Value) -> Result[SectionSpec, string] {
    Ok(SectionSpec { filter: section(params)?, scope: scope(params)?, attrs: attrs(), syms: sym_map(), extra: [] })
}

fn check(params: Value) -> Result[CheckResult, string] {
    section::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    if section::apply(params, spec(params)?)? { postcondition(params)? }
    Ok(ApplyResult::Success)
}
