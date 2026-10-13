use value
use common
use collection

// ---------------------------------------------------------------------------
// One output cache profile.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/caching")
}

fn collection(params: Value) -> Result[string, string] {
    Ok("profiles")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["extension", "extension", "str"],
    ])
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["policy", "policy", "sym"],
        ["kernel_cache_policy", "kernelCachePolicy", "sym"],
        ["duration", "duration", "dur"],
        ["location", "location", "sym"],
        ["vary_by_headers", "varyByHeaders", "str"],
        ["vary_by_query_string", "varyByQueryString", "str"],
    ])
}

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["policy", "dont_cache", "DontCache"],
        ["policy", "cache_until_change", "CacheUntilChange"],
        ["policy", "cache_for_time_period", "CacheForTimePeriod"],
        ["policy", "disable_cache", "DisableCache"],
        ["kernel_cache_policy", "dont_cache", "DontCache"],
        ["kernel_cache_policy", "cache_until_change", "CacheUntilChange"],
        ["kernel_cache_policy", "cache_for_time_period", "CacheForTimePeriod"],
        ["kernel_cache_policy", "disable_cache", "DisableCache"],
        ["location", "any", "Any"],
        ["location", "client", "Client"],
        ["location", "downstream", "Downstream"],
        ["location", "server", "Server"],
        ["location", "none", "None"],
        ["location", "server_and_client", "ServerAndClient"],
    ] }

// IIS attributes this resource owns outright: written even when
// empty, so an inherited value can be cleared rather than kept.
fn always_write() -> List[string] { [] }

fn spec(params: Value) -> Result[CollectionSpec, string] {
    Ok(CollectionSpec {
        section: section(params)?,
        collection: collection(params)?,
        scope: scope(params)?,
        keys: keys(params)?,
        attrs: attrs(params)?,
        syms: sym_map(),
        always_write: always_write(),
        required: [],
    })
}

fn check(params: Value) -> Result[CheckResult, string] {
    collection::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    collection::apply(params, spec(params)?)
}
