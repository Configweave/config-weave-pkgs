use value
use common
use section

// ---------------------------------------------------------------------------
// Output caching; the per-extension profiles are
// windows_iis.output_cache_profile.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/caching")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["enabled", "enabled", "bool"],
        ["enable_kernel_cache", "enableKernelCache", "bool"],
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
