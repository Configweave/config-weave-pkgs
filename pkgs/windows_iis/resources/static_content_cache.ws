use value
use common
use section

// ---------------------------------------------------------------------------
// The client cache headers static files carry.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/staticContent")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["cache_control_mode", "clientCache.cacheControlMode", "sym"],
        ["cache_control_max_age", "clientCache.cacheControlMaxAge", "dur"],
        ["cache_control_custom", "clientCache.cacheControlCustom", "str"],
        ["set_e_tag", "clientCache.setEtag", "bool"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["cache_control_mode", "no_control", "NoControl"],
        ["cache_control_mode", "disable_cache", "DisableCache"],
        ["cache_control_mode", "use_max_age", "UseMaxAge"],
        ["cache_control_mode", "use_expires", "UseExpires"],
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
