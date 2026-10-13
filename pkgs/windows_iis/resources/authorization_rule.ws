use value
use common
use collection

// ---------------------------------------------------------------------------
// A URL authorization rule. IIS's schema makes the whole (accessType,
// users, roles, verbs) tuple the element's key, but this resource finds the
// rule by (users, roles, verbs) alone and sets accessType on it: flipping
// access_type edits the rule in place rather than adding a second rule for
// the same principals. Changing users, roles or verbs names a different rule
// — retire the old one with ensure = :absent.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/security/authorization")
}

fn collection(params: Value) -> Result[string, string] {
    Ok("")
}

fn scope(params: Value) -> Result[string, string] { common::scope_delegated(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["users", "users", "str"],
        ["roles", "roles", "str"],
        ["verbs", "verbs", "str"],
    ])
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["access_type", "accessType", "sym"],
    ])
}

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [
        ["access_type", "allow", "Allow"],
        ["access_type", "deny", "Deny"],
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
