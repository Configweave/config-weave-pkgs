use value
use common
use collection

// ---------------------------------------------------------------------------
// One key/value pair in a rewrite map.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let map = common::param_str(params, "map", "")
    if map == "" { return Err("missing 'map' parameter") }
    Ok("system.webServer/rewrite/rewriteMaps/rewriteMap[@name='" + common::xp(map)? + "']")
}

fn collection(params: Value) -> Result[string, string] {
    Ok("")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["key", "key", "str"],
    ])
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["value", "value", "str"],
    ])
}

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

// IIS attributes this resource owns outright: written even when
// empty, so an inherited value can be cleared rather than kept.
fn always_write() -> List[string] { [] }

// Checked before apply mutates anything.
fn precondition(params: Value) -> Result[unit, string] {
    common::require_rewrite()
}

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
    precondition(params)?
    collection::apply(params, spec(params)?)
}
