use value
use common
use section

// ---------------------------------------------------------------------------
// Server-wide compression. This section is not delegated, so there is no
// site, path or store to scope it with.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/httpCompression")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["directory", "directory", "str"],
        ["min_file_size_for_comp", "minFileSizeForComp", "int"],
        ["do_disk_space_limiting", "doDiskSpaceLimiting", "bool"],
        ["max_disk_space_usage", "maxDiskSpaceUsage", "int"],
        ["no_compression_for_proxies", "noCompressionForProxies", "bool"],
        ["no_compression_for_http10", "noCompressionForHttp10", "bool"],
        ["no_compression_for_range", "noCompressionForRange", "bool"],
        ["send_cache_headers", "sendCacheHeaders", "bool"],
        ["cache_control_header", "cacheControlHeader", "str"],
        ["expires_header", "expiresHeader", "str"],
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
