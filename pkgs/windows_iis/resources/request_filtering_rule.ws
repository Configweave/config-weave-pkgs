use value
use common
use collection

// ---------------------------------------------------------------------------
// One request filtering entry. The five lists are the same shape but name
// their value differently — fileExtension, verb, segment, sequence, url —
// so the collection and its key attribute both come from `kind`.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/requestFiltering")
}

fn collection(params: Value) -> Result[string, string] {
    let kind = common::param_str(params, "kind", "")
    if kind == "file_extension" { return Ok("fileExtensions") }
    if kind == "verb" { return Ok("verbs") }
    if kind == "hidden_segment" { return Ok("hiddenSegments") }
    if kind == "denied_url_sequence" { return Ok("denyUrlSequences") }
    if kind == "always_allowed_url" { return Ok("alwaysAllowedUrls") }
    Err("invalid 'kind' value '" + kind + "' (expected :file_extension, :verb, :hidden_segment, :denied_url_sequence or :always_allowed_url)")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    let kind = common::param_str(params, "kind", "")
    if kind == "file_extension" { return Ok([["value", "fileExtension", "str"]]) }
    if kind == "verb" { return Ok([["value", "verb", "str"]]) }
    if kind == "hidden_segment" { return Ok([["value", "segment", "str"]]) }
    if kind == "denied_url_sequence" { return Ok([["value", "sequence", "str"]]) }
    if kind == "always_allowed_url" { return Ok([["value", "url", "str"]]) }
    Err("invalid 'kind' value '" + kind + "'")
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    let none: List[List[string]] = []
    let kind = common::param_str(params, "kind", "")
    if kind == "file_extension" || kind == "verb" {
        return Ok([["allowed", "allowed", "bool"]])
    }
    Ok(none)
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
