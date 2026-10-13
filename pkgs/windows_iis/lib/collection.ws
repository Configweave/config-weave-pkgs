use value
use json
use log
use common

// ---------------------------------------------------------------------------
// Collection machinery: find-by-key, add-or-update, remove-by-key over one
// element of an IIS configuration collection. A collection script declares a
// CollectionSpec and hands it to check() and apply() here.
// ---------------------------------------------------------------------------

// section:      the section path, e.g. system.webServer/staticContent.
// collection:   the child collection under it, or "" when the section IS the
//               collection, as system.webServer/handlers is.
// scope:        the -PSPath/-Location arguments.
// keys:         [param, IIS attribute, kind] rows identifying the element.
// attrs:        [param, IIS attribute, kind] rows set on the element.
// syms:         [param, symbol value, IIS token] rows.
// always_write: IIS attributes this resource owns outright: written even
//               when empty, so an inherited value can be cleared rather than
//               kept.
// required:     string params that must be non-empty when ensure is
//               :present.
// create_required: string params that must be non-empty to add the element
//               when it is not there yet.
struct CollectionSpec {
    section: string,
    collection: string,
    scope: string,
    keys: List[List[string]],
    attrs: List[List[string]],
    syms: List[List[string]],
    always_write: List[string],
    required: List[string],
    create_required: List[string],
}

fn iis_symbol(spec: CollectionSpec, name: string, v: string) -> string {
    for row in spec.syms {
        if row.get(0).unwrap_or("") == name && row.get(1).unwrap_or("") == v {
            return row.get(2).unwrap_or("")
        }
    }
    v
}

// Unlike a section attribute, an element is written whole, so an empty
// string here is a real value rather than "leave it alone" — there is no
// inherited element to leave alone.
fn text_of(params: Value, spec: CollectionSpec, name: string, kind: string) -> string {
    if kind == "bool" {
        if common::param_bool(params, name, false) { return "true" }
        return "false"
    }
    if kind == "int" { return common::itoa(common::param_int(params, name, 0)) }
    if kind == "dur" { return common::hms(common::param_int(params, name, 0)) }
    if kind == "dur_sec" { return common::itoa(common::param_int(params, name, 0) / 1000000000) }
    if kind == "dur_ms" { return common::itoa(common::param_int(params, name, 0) / 1000000) }
    if kind == "flags" || kind == "vlist" { return common::param_list(params, name).join(",") }
    if kind == "sym" { return iis_symbol(spec, name, common::param_str(params, name, "")) }
    common::param_str(params, name, "")
}

// [attribute, kind, text] for the rows that identify the element.
fn key_rows(params: Value, spec: CollectionSpec) -> List[List[string]] {
    let out: List[List[string]] = []
    for a in spec.keys {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        out.push([a.get(1).unwrap_or(""), kind, text_of(params, spec, name, kind)])
    }
    out
}

// [attribute, kind, text] for the rows the step wants set on the element.
// Optional strings the step left empty are skipped so IIS keeps its own
// default rather than being handed "".
fn attr_rows(params: Value, spec: CollectionSpec) -> List[List[string]] {
    let out: List[List[string]] = []
    for a in spec.attrs {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        if !common::has(params, name) { continue }
        let text = text_of(params, spec, name, kind)
        let owned = spec.always_write.contains(a.get(1).unwrap_or(""))
        if text == "" && !owned && (kind == "str" || kind == "sym") { continue }
        out.push([a.get(1).unwrap_or(""), kind, text])
    }
    out
}

fn same(kind: string, have: string, want: string) -> bool {
    if kind == "flags" { return common::same_flags(have, want) }
    if kind == "bool" || kind == "sym" {
        return have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
    }
    have == want
}

fn ps_literal(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    if kind == "int" || kind == "dur_sec" || kind == "dur_ms" { return want }
    common::ps_q(want)
}

// A PowerShell hashtable of attribute assignments, the shape
// Add-/Remove-WebConfigurationProperty take for -Value and -AtElement.
fn ps_hash(rows: List[List[string]]) -> string {
    let parts: List[string] = []
    for r in rows {
        parts.push(r.get(0).unwrap_or("") + "=" + ps_literal(r.get(1).unwrap_or(""), r.get(2).unwrap_or("")))
    }
    "@{{" + parts.join("; ") + "}}"
}

// The collection's own filter: the section itself when the section IS the
// collection, as system.webServer/handlers is, otherwise the named child.
fn coll_filter(spec: CollectionSpec) -> string {
    if spec.collection == "" { return spec.section }
    spec.section + "/" + spec.collection
}

// 'ABSENT', or a JSON object of the attributes this step cares about, plus
// "__tag" (the element's schema tag: add, error, mimeMap) and "__key_<attr>"
// for each key as IIS stores it.
//
// The element is found in GetCollection() by a case-insensitive -eq, as IIS
// itself matches collection keys. Those raw Microsoft.Web.Administration
// elements do not expose attributes as properties, so everything is read with
// GetAttributeValue, and an enum through CwEnum, which maps the ordinal
// GetAttributeValue returns back to its schema name.
fn probe(params: Value, spec: CollectionSpec) -> Result[string, string] {
    let get_coll = if spec.collection == "" { "$s.GetCollection()" } else { "$s.GetCollection(" + common::ps_q(spec.collection) + ")" }
    let tests: List[string] = []
    let keys = ""
    for r in key_rows(params, spec) {
        let a = r.get(0).unwrap_or("")
        let v = r.get(2).unwrap_or("")
        common::xp(v)?
        tests.push("[string]$_.GetAttributeValue(" + common::ps_q(a) + ") -eq " + common::ps_q(v))
        keys = keys + "$o[" + common::ps_q("__key_" + a) + "]=[string]$m[-1].GetAttributeValue(" + common::ps_q(a) + "); "
    }
    let reads = ""
    for r in attr_rows(params, spec) {
        let a = r.get(0).unwrap_or("")
        let qa = common::ps_q(a)
        if r.get(1).unwrap_or("") == "sym" || r.get(1).unwrap_or("") == "flags" {
            // Called with SPACE-separated arguments, not a parenthesised list:
            // in PowerShell `CwEnum($a, $b, $c)` passes ONE argument — the
            // three-element array.
            reads = reads + "$o[" + qa + "]=(CwEnum $m[-1] " + qa + " (CwV($m[-1].GetAttributeValue(" + qa + ")))); "
        } else {
            reads = reads + "$o[" + qa + "]=CwV($m[-1].GetAttributeValue(" + qa + ")); "
        }
    }
    // No top-level `return`: PowerShell -Command treats one as a script-level
    // exit and the caller sees a failure with nothing on stderr.
    common::ps_out(
        "$s = $null; try {{ $s = Get-WebConfiguration" + spec.scope + " -Filter " +
        common::ps_q(spec.section) + " }} catch {{ }}; " +
        "if ($null -eq $s) {{ 'ABSENT' }} else {{ " +
        "$m = @(" + get_coll + " | Where-Object {{ " + tests.join(" -and ") + " }}); " +
        "if ($m.Count -eq 0) {{ 'ABSENT' }} else {{ " +
        "$o=@{{}}; $o['__tag']=[string]$m[-1].ElementTagName; " + keys + reads +
        "[pscustomobject]$o | ConvertTo-Json -Compress }} }}")
}

// The key rows as IIS stores them. A key that differs from the step's only in
// case is the same element to IIS, but an XPath predicate or -AtElement built
// from the step's spelling would miss it.
fn live_keys(params: Value, spec: CollectionSpec, have: Value) -> List[List[string]] {
    let out: List[List[string]] = []
    for r in key_rows(params, spec) {
        let a = r.get(0).unwrap_or("")
        out.push([a, r.get(1).unwrap_or(""), common::get_str(have, "__key_" + a)])
    }
    out
}

// The XPath addressing the live element inside its collection.
fn element_filter(params: Value, spec: CollectionSpec, have: Value) -> Result[string, string] {
    let tag = common::get_str(have, "__tag")
    if tag == "" { return Err("could not read the element's tag name") }
    let out = coll_filter(spec) + "/" + tag
    for r in live_keys(params, spec, have) {
        out = out + "[@" + r.get(0).unwrap_or("") + "='" + common::xp(r.get(2).unwrap_or(""))? + "']"
    }
    Ok(out)
}

// Names and required params checked in check() as well as apply(), so a bad
// step fails loudly rather than reporting drift for ever.
fn validate(params: Value, spec: CollectionSpec) -> Result[unit, string] {
    for r in spec.keys.concat(spec.attrs) { common::attr_name("attribute", r.get(1).unwrap_or(""))? }
    if !common::want_present(params)? { return Ok(()) }
    for name in spec.required {
        if common::param_str(params, name, "") == "" {
            return Err("'" + name + "' is required when ensure is :present")
        }
    }
    Ok(())
}

fn can_create(params: Value, spec: CollectionSpec) -> Result[unit, string] {
    for name in spec.create_required {
        if common::param_str(params, name, "") == "" {
            return Err("'" + name + "' is required to add the element, which is not there yet")
        }
    }
    Ok(())
}

fn check(params: Value, spec: CollectionSpec) -> Result[CheckResult, string] {
    validate(params, spec)?
    let st = probe(params, spec)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" {
        can_create(params, spec)?
        return Ok(CheckResult::NotConfigured)
    }
    let have = json::parse(st)?
    for r in attr_rows(params, spec) {
        if !same(r.get(1).unwrap_or(""), common::get_str(have, r.get(0).unwrap_or("")), r.get(2).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value, spec: CollectionSpec) -> Result[ApplyResult, string] {
    validate(params, spec)?
    let st = probe(params, spec)?
    let filter = common::ps_q(coll_filter(spec))
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing element from " + coll_filter(spec))
        common::ps_run("Remove-WebConfigurationProperty" + spec.scope + " -Filter " + filter +
            " -Name '.' -AtElement " + ps_hash(live_keys(params, spec, json::parse(st)?)))?
        return Ok(ApplyResult::Success)
    }
    if st == "ABSENT" {
        can_create(params, spec)?
        log::info("adding element to " + coll_filter(spec))
        common::ps_run("Add-WebConfigurationProperty" + spec.scope + " -Filter " + filter +
            " -Name '.' -Value " + ps_hash(key_rows(params, spec).concat(attr_rows(params, spec))))?
        return Ok(ApplyResult::Success)
    }
    // The element is there: set the attributes that differ on it in place.
    // Remove-and-re-add would also work for an element this level owns, but
    // it moves the element to the end of the collection, which matters
    // wherever order does — handlers, rewrite rules.
    let have = json::parse(st)?
    let elem = element_filter(params, spec, have)?
    let script = ""
    for r in attr_rows(params, spec) {
        let a = r.get(0).unwrap_or("")
        let kind = r.get(1).unwrap_or("")
        let want = r.get(2).unwrap_or("")
        if same(kind, common::get_str(have, a), want) { continue }
        script = script + common::set_prop(spec.scope, common::ps_q(elem), a, ps_literal(kind, want),
            common::get_str(have, a), want)
    }
    if script == "" { return Ok(ApplyResult::Success) }
    log::info("updating element in " + coll_filter(spec))
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
