use value
use common
use collection

// ---------------------------------------------------------------------------
// One compression entry. The collection is chosen by `kind`: staticTypes
// covers responses served from disk, dynamicTypes ones an application
// generated. Server-wide — httpCompression is not delegated.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/httpCompression")
}

fn collection(params: Value) -> Result[string, string] {
    let kind = common::param_str(params, "kind", "static")
    if kind == "static" { return Ok("staticTypes") }
    if kind == "dynamic" { return Ok("dynamicTypes") }
    Err("invalid 'kind' value '" + kind + "' (expected :static or :dynamic)")
}

fn scope(params: Value) -> Result[string, string] { common::scope_apphost(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["mime_type", "mimeType", "str"],
    ])
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["enabled", "enabled", "bool"],
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
        required: [],
    })
}

fn check(params: Value) -> Result[CheckResult, string] {
    collection::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    collection::apply(params, spec(params)?)
}
