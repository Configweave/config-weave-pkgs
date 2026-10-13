use value
use common
use section

// ---------------------------------------------------------------------------
// The two section-level switches on <isapiCgiRestriction>. Unlisted
// executables are refused by default, which is the safe posture; these
// are the knobs that relax it. Server-wide.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/isapiCgiRestriction")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["allow_unlisted_isapis", "notListedIsapisAllowed", "bool"],
        ["allow_unlisted_cgis", "notListedCgisAllowed", "bool"],
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
