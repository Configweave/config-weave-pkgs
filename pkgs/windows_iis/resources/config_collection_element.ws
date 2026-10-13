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
// string where it wants a number or a flag.
fn map_pairs(params: Value, key: string) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    if let Some(m) = params.get(key) {
        if m.is_null() { return Ok(out) }
        if m.as_map().is_none() { return Err("'" + key + "' must be a map") }
        for name in m.keys() {
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
    Ok(section(params)? + "/" + coll)
}

fn ps_hash(pairs: List[List[string]]) -> string {
    let parts: List[string] = []
    for p in pairs { parts.push(p.get(0).unwrap_or("") + "=" + p.get(1).unwrap_or("")) }
    "@{{" + parts.join("; ") + "}}"
}

// 'ABSENT', or a JSON object of the attributes this step names.
fn probe(params: Value) -> Result[string, string] {
    let coll = common::param_str(params, "collection_name", "")
    let get_coll = if coll == "" { "$s.GetCollection()" } else { "$s.GetCollection(" + common::ps_q(coll) + ")" }
    let tests: List[string] = []
    for p in key_pairs(params)? {
        tests.push("[string]$_.GetAttributeValue(" + common::ps_q(p.get(0).unwrap_or("")) + ") -eq " +
            common::ps_q(p.get(2).unwrap_or("")))
    }
    let predicates = ""
    for p in key_pairs(params)? {
        predicates = predicates + "[@" + p.get(0).unwrap_or("") + "='" +
            common::xp(p.get(2).unwrap_or(""))? + "']"
    }
    let tmpl = coll_filter(params)? + "/@TAG@" + predicates
    let reads = ""
    for p in map_pairs(params, "attributes")? {
        let a = common::ps_q(p.get(0).unwrap_or(""))
        reads = reads + "$o[" + a + "]=CwV($m[-1].GetAttributeValue(" + a + ")); "
    }
    common::ps_out(
        // No top-level `return`: PowerShell -Command treats one as a
        // script-level exit and the caller sees a failure with an empty stderr.
        "$s = $null; try {{ $s = Get-WebConfiguration" + common::scope_delegated(params)? + " -Filter " +
        common::ps_q(section(params)?) + " }} catch {{ }}; " +
        "if ($null -eq $s) {{ 'ABSENT' }} else {{ " +
        "$m = @(" + get_coll + " | Where-Object {{ " + tests.join(" -and ") + " }}); " +
        "if ($m.Count -eq 0) {{ 'ABSENT' }} else {{ $o=@{{}}; " +
        "$o['__tag']=[string]$m[-1].ElementTagName; " + reads +
        "[pscustomobject]$o | ConvertTo-Json -Compress }} }}")
}

// The XPath addressing this element inside its collection. The tag is the
// schema's — add, error, mimeMap — so it comes from the probe.
fn element_filter(params: Value) -> Result[string, string] {
    let tag = common::get_str(json::parse(probe(params)?)?, "__tag")
    if tag == "" { return Err("could not read the element's tag name") }
    let out = coll_filter(params)? + "/" + tag
    for p in key_pairs(params)? {
        out = out + "[@" + p.get(0).unwrap_or("") + "='" + common::xp(p.get(2).unwrap_or(""))? + "']"
    }
    Ok(out)
}

fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
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
        let a = p.get(0).unwrap_or("")
        if !same(common::get_str(have, a), p.get(2).unwrap_or("")) { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let st = probe(params)?
    let scope = common::scope_delegated(params)?
    let filter = common::ps_q(coll_filter(params)?)
    let at = ps_hash(key_pairs(params)?)
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing element from " + coll_filter(params)?)
        common::ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + filter +
            " -Name '.' -AtElement " + at)?
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
    let elem = element_filter(params)?
    let script = ""
    for p in map_pairs(params, "attributes")? {
        let a = p.get(0).unwrap_or("")
        if same(common::get_str(have, a), p.get(2).unwrap_or("")) { continue }
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " + common::ps_q(elem) +
            " -Name " + common::ps_q(a) + " -Value " + p.get(1).unwrap_or("") + "; "
    }
    if script == "" { return Ok(ApplyResult::Success) }
    log::info("updating element in " + coll_filter(params)?)
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
