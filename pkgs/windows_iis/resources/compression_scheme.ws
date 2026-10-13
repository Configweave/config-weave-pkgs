use value
use common
use collection

// ---------------------------------------------------------------------------
// One compression scheme (gzip, br). The compression LEVELS live here
// rather than on <httpCompression>: they are attributes of <scheme>, and
// setting them on the section is a schema error. Static content is
// compressed once and cached, so a high static level is nearly free;
// every dynamic response is compressed afresh, so that level trades CPU
// for bandwidth on each request. Server-wide.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/httpCompression")
}

fn collection(params: Value) -> Result[string, string] {
    Ok("")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["name", "name", "str"],
    ])
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["dll", "dll", "str"],
        ["static_compression_level", "staticCompressionLevel", "int"],
        ["dynamic_compression_level", "dynamicCompressionLevel", "int"],
    ])
}

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

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
    })
}

fn check(params: Value) -> Result[CheckResult, string] {
    collection::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    collection::apply(params, spec(params)?)
}
