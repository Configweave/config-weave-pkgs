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

// A typed param as [text git stores, kind], where kind is "bool", "int" or
// "text" (strings and symbols). None = leave this setting alone: either the
// step omitted the param — the only way a bool or int param can say that,
// since a declared default would instead mean "set it to false" / "set it
// to 0" — or it passed an empty string, which means the same thing.
// Removing a key is git.config_entry's job (ensure = :absent).
fn to_cfg(params: Value, name: string) -> Option[List[string]] {
    if let Some(v) = params.get(name) {
        if let Some(s) = v.as_string() {
            if s == "" { return None }
            return Some([s, "text"])
        }
        if let Some(b) = v.as_bool() {
            if b { return Some(["true", "bool"]) }
            return Some(["false", "bool"])
        }
        if let Some(i) = v.as_int() { return Some([json::to_string(Value::Int(i)), "int"]) }
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

// The [git key, desired text, kind] triples this step actually asks for.
// Params the step omitted are absent from `params` and so are skipped.
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
        if let Some(cfg) = to_cfg(params, snake(key)) {
            let value = cfg.get(0).unwrap_or("")
            if hyphenated.contains(key) { value = value.replace("_", "-") }
            out.push([section + "." + key, value, cfg.get(1).unwrap_or("text")])
        }
    }
    out
}

// Converged = exactly one value, equal to the desired one, since apply
// writes with --replace-all. bool and int params are read back through
// git's --type, so git does the canonicalising; strings and symbols fold
// only the word spellings of a boolean, never digits, because many of
// them (merge.log, status.submoduleSummary) are bool-or-int.
fn matches(params: Value, triple: List[string]) -> Result[bool, string] {
    let key = triple.get(0).unwrap_or("")
    let want = triple.get(1).unwrap_or("")
    let kind = triple.get(2).unwrap_or("text")
    let have = if kind == "text" { common::cfg_get_all(params, key)? } else { common::cfg_get_typed(params, key, kind)? }
    if have.len() != 1 { return Ok(false) }
    let got = have.get(0).unwrap_or("")
    if kind == "text" { return Ok(common::fold_words(got) == common::fold_words(want)) }
    Ok(got == want)
}

fn check(params: Value, section: string, keys: List[string], hyphenated: List[string]) -> Result[CheckResult, string] {
    for triple in desired(params, section, keys, hyphenated) {
        if !matches(params, triple)? { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value, section: string, keys: List[string], hyphenated: List[string]) -> Result[ApplyResult, string] {
    for triple in desired(params, section, keys, hyphenated) {
        if !matches(params, triple)? {
            let key = triple.get(0).unwrap_or("")
            let want = triple.get(1).unwrap_or("")
            log::info("setting " + key + " = " + want)
            common::cfg_set(params, key, want)?
        }
    }
    Ok(ApplyResult::Success)
}
