use value
use json
use log
use common

// The machinery behind the 13 section resources (git.user, git.core, …).
// Each of those declares only `section()`, `keys()` (git's canonical
// spelling) and `hyphenated()` (the keys whose symbol values carry a
// hyphen), and hands them to check() / apply() here. The legal values
// themselves live in package.wcl, where config-weave validates them and
// the docs list them.

// A typed param rendered as the text git stores. None = the step omitted
// the param, which means "leave this setting alone" — the only way a bool
// or int param can express that, since a declared default would instead
// mean "set it to false" / "set it to 0".
fn to_cfg(params: Value, name: string) -> Option[string] {
    if let Some(v) = params.get(name) {
        if let Some(s) = v.as_string() { return Some(s) }
        if let Some(b) = v.as_bool() {
            if b { return Some("true") }
            return Some("false")
        }
        if let Some(i) = v.as_int() { return Some(json::to_string(Value::Int(i))) }
    }
    None
}

// "signingKey" -> "signing_key". Params keep the repo's snake_case naming
// while `keys()` carries git's canonical spelling, so git's own casing is
// what lands in the file. Requires keys() entries to be lowerCamelCase with
// no consecutive capitals (which is why core.protectNTFS is not exposed).
fn snake(k: string) -> string {
    let out = k
    for u in ["A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
              "N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z"] {
        out = out.replace(u, "_" + u.to_lower())
    }
    out
}

// The [git key, desired text] pairs this step actually asks for. Params the
// step omitted are absent from `params` and so are skipped entirely.
//
// config-weave validates a symbol param against the `symbol` values the
// package declares, so all that is left here is spelling: WCL symbols
// cannot contain hyphens — the lexer stops at [A-Za-z0-9_] — so git's
// "on-demand" is declared :on_demand and the hyphen put back here. No
// legal value of the `hyphenated` keys contains an underscore, so the
// substitution is unambiguous.
fn desired(params: Value, section: string, keys: List[string], hyphenated: List[string]) -> List[List[string]] {
    let out: List[List[string]] = []
    for key in keys {
        if let Some(raw) = to_cfg(params, snake(key)) {
            let value = raw
            if hyphenated.contains(key) { value = raw.replace("_", "-") }
            out.push([section + "." + key, value])
        }
    }
    out
}

// An explicit empty string reads back as "unset" and so is a no-op here;
// use git.config_entry with ensure = :absent to remove a key.
fn check(params: Value, section: string, keys: List[string], hyphenated: List[string]) -> Result[CheckResult, string] {
    for pair in desired(params, section, keys, hyphenated) {
        let key = pair.get(0).unwrap_or("")
        let want = pair.get(1).unwrap_or("")
        let have = common::cfg_get(params, key)?
        if common::norm(have.unwrap_or("")) != common::norm(want) { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value, section: string, keys: List[string], hyphenated: List[string]) -> Result[ApplyResult, string] {
    for pair in desired(params, section, keys, hyphenated) {
        let key = pair.get(0).unwrap_or("")
        let want = pair.get(1).unwrap_or("")
        let have = common::cfg_get(params, key)?
        if common::norm(have.unwrap_or("")) != common::norm(want) {
            log::info("setting " + key + " = " + want)
            common::cfg_set(params, key, want)?
        }
    }
    Ok(ApplyResult::Success)
}
