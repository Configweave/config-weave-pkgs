use value
use common
use collection

// ---------------------------------------------------------------------------
// One environment variable on a FastCGI application.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let full = common::param_str(params, "full_path", "")
    if full == "" { return Err("missing 'full_path' parameter") }
    Ok("system.webServer/fastCgi/application[@fullPath='" + common::xp(full)? +
        "'][@arguments='" + common::xp(common::param_str(params, "arguments", ""))? + "']")
}

fn collection(params: Value) -> Result[string, string] {
    Ok("environmentVariables")
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
        ["value", "value", "str"],
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
