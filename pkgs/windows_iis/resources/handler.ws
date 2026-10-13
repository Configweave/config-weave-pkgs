use value
use common
use collection

// ---------------------------------------------------------------------------
// One handler mapping. IIS picks a handler by walking the collection in
// order and taking the FIRST entry whose path and verb match — there is no
// "most specific wins" — so position matters. A new handler is added at the
// end of the collection, behind the inherited catch-alls such as
// StaticFile (path="*"), and an existing one is updated in place. A handler
// that must sit ahead of another needs the collection ordered explicitly,
// which this resource does not do: write it with config_collection_element
// on a collection this level clears and owns.
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

fn spec(params: Value) -> Result[CollectionSpec, string] {
    Ok(CollectionSpec {
        section: section(params)?,
        collection: collection(params)?,
        scope: scope(params)?,
        keys: keys(params)?,
        attrs: attrs(params)?,
        syms: sym_map(),
        always_write: always_write(),
        required: ["path_pattern"],
        create_required: [],
    })
}

fn check(params: Value) -> Result[CheckResult, string] {
    collection::check(params, spec(params)?)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    collection::apply(params, spec(params)?)
}
