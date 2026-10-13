use value
use common
use collection

// ---------------------------------------------------------------------------
// One ISAPI filter registration, at the server level or under a site.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/isapiFilters")
}

fn collection(params: Value) -> Result[string, string] {
    Ok("")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["name", "name", "str"],
    ])
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["filter_path", "path", "str"],
        ["enabled", "enabled", "bool"],
        ["precondition", "preCondition", "str"],
        ["enable_cache", "enableCache", "bool"],
    ])
}

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

// IIS attributes this resource owns outright: written even when
// empty, so an inherited value can be cleared rather than kept.
fn always_write() -> List[string] { [] }

// Checked before apply mutates anything.
fn precondition(params: Value) -> Result[unit, string] {
    if common::want_present(params)? && common::param_str(params, "filter_path", "") == "" {
        return Err("'filter_path' is required when ensure is :present")
    }
    Ok(())
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
