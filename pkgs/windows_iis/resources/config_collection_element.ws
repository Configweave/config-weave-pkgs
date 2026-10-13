use value
use json
use log
use common

// ---------------------------------------------------------------------------
// The untyped escape hatch for a collection element: anything in IIS's schema
// shaped like "a list of things identified by some attributes".
//
// `keys` identifies the element and `attributes` is what gets set on it. As
// with the typed collection resources, an element that already exists is
// updated in place rather than removed and re-added, so its position in the
// collection is kept — which matters wherever order does.
// ---------------------------------------------------------------------------

// A map param rendered as PowerShell assignments. WCL gives strings, ints and
// bools; each has to reach IIS as its own type, because the schema rejects a
// string where it wants a number or a flag. The attribute names are spliced
// into PowerShell and XPath unquoted, so they are held to the characters an
// IIS attribute name can have.
fn map_pairs(params: Value, key: string) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    if let Some(m) = params.get(key) {
        if m.is_null() { return Ok(out) }
        if m.as_map().is_none() { return Err("'" + key + "' must be a map") }
        for name in m.keys() {
            common::attr_name(key, name)?
            if let Some(v) = m.get(name) {
                if let Some(s) = v.as_string() { out.push([name, common::ps_q(s), s]) }
                else if let Some(i) = v.as_int() { out.push([name, common::itoa(i), common::itoa(i)]) }
                else if let Some(b) = v.as_bool() {
                    if b { out.push([name, "$true", "true"]) } else { out.push([name, "$false", "false"]) }
                } else {
                    return Err("'" + key + "." + name + "' must be a string, int or bool")
                }
            }
        }
    }
    Ok(out)
}

fn key_pairs(params: Value) -> Result[List[List[string]], string] {
    let ks = map_pairs(params, "keys")?
    if ks.is_empty() { return Err("'keys' must name at least one attribute") }
    for p in ks { common::xp(p.get(2).unwrap_or(""))? }
    Ok(ks)
}

fn section(params: Value) -> Result[string, string] {
    let f = common::param_str(params, "filter", "")
    if f == "" { return Err("missing 'filter' parameter") }
    Ok(f)
}

fn coll_filter(params: Value) -> Result[string, string] {
    let coll = common::param_str(params, "collection_name", "")
    if coll == "" { return Ok(section(params)?) }
    Ok(section(params)? + "/" + common::attr_name("collection_name", coll)?)
}

fn ps_hash(pairs: List[List[string]]) -> string {
    let parts: List[string] = []
    for p in pairs { parts.push(p.get(0).unwrap_or("") + "=" + p.get(1).unwrap_or("")) }
    "@{{" + parts.join("; ") + "}}"
}

// 'ABSENT', or a JSON object of the attributes this step names, plus
// "__tag", "__key_<attr>" (each key as IIS stores it) and "__kind_<attr>"
// (enum, flags or empty, from the schema).
//
// The raw elements GetCollection() yields hand an enum back as its ordinal, so
// keys and attributes are read through CwEnum, which maps it to the schema
// name; anything else passes through as CwV renders it.
fn probe(params: Value) -> Result[string, string] {
    let coll = common::param_str(params, "collection_name", "")
    let get_coll = if coll == "" { "$s.GetCollection()" } else { "$s.GetCollection(" + common::ps_q(coll) + ")" }
    let tests: List[string] = []
    let keys = ""
    for p in key_pairs(params)? {
        let a = common::ps_q(p.get(0).unwrap_or(""))
        tests.push("(CwEnum $_ " + a + " ([string]$_.GetAttributeValue(" + a + "))) -eq " +
            common::ps_q(p.get(2).unwrap_or("")))
        keys = keys + "$o[" + common::ps_q("__key_" + p.get(0).unwrap_or("")) + "]=(CwEnum $m[-1] " + a +
            " ([string]$m[-1].GetAttributeValue(" + a + "))); " +
            "$o[" + common::ps_q("__raw_" + p.get(0).unwrap_or("")) + "]=[string]$m[-1].GetAttributeValue(" + a + "); " +
            "$o[" + common::ps_q("__kind_" + p.get(0).unwrap_or("")) + "]=(CwKind $m[-1] " + a + "); "
    }
    let reads = ""
    for p in map_pairs(params, "attributes")? {
        let a = common::ps_q(p.get(0).unwrap_or(""))
        let k = common::ps_q("__kind_" + p.get(0).unwrap_or(""))
        reads = reads + "$o[" + a + "]=(CwEnum $m[-1] " + a + " (CwV($m[-1].GetAttributeValue(" + a + ")))); " +
            "$o[" + k + "]=(CwKind $m[-1] " + a + "); "
    }
    common::ps_out(
        // No top-level `return`: PowerShell -Command treats one as a
        // script-level exit and the caller sees a failure with an empty stderr.
        "$s = $null; try {{ $s = Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(section(params)?) + " }} catch {{ }}; " +
        "if ($null -eq $s) {{ 'ABSENT' }} else {{ " +
        "$m = @(" + get_coll + " | Where-Object {{ " + tests.join(" -and ") + " }}); " +
        "if ($m.Count -eq 0) {{ 'ABSENT' }} else {{ $o=@{{}}; " +
        "$o['__tag']=[string]$m[-1].ElementTagName; " + keys + reads +
        "[pscustomobject]$o | ConvertTo-Json -Compress }} }}")
}

// The key pairs as IIS stores them: a key that differs from the step's only
// in case is the same element to IIS, but an XPath predicate or -AtElement
// spelled the step's way would miss it. -AtElement matches an enum key only
// by its ordinal — given the name it warns "Property . is not found" and
// removes nothing — so an enum key's literal is the raw number, and it
// matches strings as wildcard patterns, so a string key is escaped.
fn live_keys(params: Value, have: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    for p in key_pairs(params)? {
        let a = p.get(0).unwrap_or("")
        let v = common::get_str(have, "__key_" + a)
        let lit = p.get(1).unwrap_or("")
        if common::get_str(have, "__kind_" + a) != "" { lit = common::get_str(have, "__raw_" + a) }
        else if lit.starts_with("'") { lit = common::ps_at(v) }
        out.push([a, lit, v])
    }
    Ok(out)
}

// The XPath addressing the live element inside its collection. The tag is
// the schema's — add, error, mimeMap — so it comes from the probe.
fn element_filter(params: Value, have: Value) -> Result[string, string] {
    let tag = common::get_str(have, "__tag")
    if tag == "" { return Err("could not read the element's tag name") }
    let out = coll_filter(params)? + "/" + tag
    for p in live_keys(params, have)? {
        out = out + "[@" + p.get(0).unwrap_or("") + "='" + common::xp(p.get(2).unwrap_or(""))? + "']"
    }
    Ok(out)
}

// Enum names and booleans are compared case-insensitively, flags as sets;
// strings and numbers exactly, as IIS stores them.
fn same(kind: string, have: string, want: string) -> bool {
    if kind == "flags" { return common::same_flags(have, want) }
    if kind == "enum" || have == "true" || have == "false" {
        return have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
    }
    have == want
}

fn attrs_match(params: Value, have: Value, a: string, want: string) -> bool {
    same(common::get_str(have, "__kind_" + a), common::get_str(have, a), want)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let have = json::parse(st)?
    for p in map_pairs(params, "attributes")? {
        if !attrs_match(params, have, p.get(0).unwrap_or(""), p.get(2).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let st = probe(params)?
    let scope = common::scope_delegated(params)?
    let filter = common::ps_q(coll_filter(params)?)
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing element from " + coll_filter(params)?)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + filter +
            " -Name '.' -AtElement " + ps_hash(live_keys(params, json::parse(st)?)?))?
        return Ok(ApplyResult::Success)
    }
    if st == "ABSENT" {
        log::info("adding element to " + coll_filter(params)?)
        common::ps_run("Add-WebConfigurationProperty" + scope + " -Filter " + filter +
            " -Name '.' -Value " +
            ps_hash(key_pairs(params)?.concat(map_pairs(params, "attributes")?)))?
        return Ok(ApplyResult::Success)
    }
    // Set the attributes that differ, in place, so the element keeps its
    // position in the collection.
    let have = json::parse(st)?
    let elem = element_filter(params, have)?
    let script = ""
    for p in map_pairs(params, "attributes")? {
        let a = p.get(0).unwrap_or("")
        if attrs_match(params, have, a, p.get(2).unwrap_or("")) { continue }
        script = script + common::set_prop(scope, common::ps_q(elem), a, p.get(1).unwrap_or(""),
            common::get_str(have, a), p.get(2).unwrap_or(""))
    }
    if script == "" { return Ok(ApplyResult::Success) }
    log::info("updating element in " + coll_filter(params)?)
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
