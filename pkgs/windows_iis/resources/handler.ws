use value
use common
use collection

// ---------------------------------------------------------------------------
// One handler mapping. A re-added handler lands at the end of the
// collection; that is safe in practice because IIS prefers the most
// specific path match (*.php beats *) before it considers order, but a
// handler that competes with another on the same path pattern should be
// placed with config_collection_element instead.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/handlers")
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
        ["path_pattern", "path", "str"],
        ["verb", "verb", "str"],
        ["type", "type", "str"],
        ["modules", "modules", "str"],
        ["script_processor", "scriptProcessor", "str"],
        ["resource_type", "resourceType", "sym"],
        ["require_access", "requireAccess", "sym"],
        ["precondition", "preCondition", "str"],
        ["allow_path_info", "allowPathInfo", "bool"],
        ["response_buffer_limit", "responseBufferLimit", "int"],
    ])
}

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["resource_type", "file", "File"],
        ["resource_type", "directory", "Directory"],
        ["resource_type", "either", "Either"],
        ["resource_type", "unspecified", "Unspecified"],
        ["require_access", "none", "None"],
        ["require_access", "read", "Read"],
        ["require_access", "write", "Write"],
        ["require_access", "script", "Script"],
        ["require_access", "execute", "Execute"],
    ] }

// IIS attributes this resource owns outright: written even when
// empty, so an inherited value can be cleared rather than kept.
fn always_write() -> List[string] { [] }

// Checked before apply mutates anything.
fn precondition(params: Value) -> Result[unit, string] {
    if common::want_present(params)? && common::param_str(params, "path_pattern", "") == "" {
        return Err("'path_pattern' is required when ensure is :present")
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
