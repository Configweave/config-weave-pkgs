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
struct CollectionSpec {
    section: string,
    collection: string,
    scope: string,
    keys: List[List[string]],
    attrs: List[List[string]],
    syms: List[List[string]],
    always_write: List[string],
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

// Attribute names the IIS PowerShell provider also uses for its OWN members on
// the objects it hands back, where the member wins and the attribute cannot be
// read at all: asking a caching profile for `location` answers with the
// -Location it was fetched from. Such an attribute is written but not compared,
// so its value is applied and drift in it is not detected. The alternative is a
// resource that reports drift for ever and never converges.
fn shadowed(attr: string) -> bool {
    for m in ["location", "filter", "pspath", "itemxpath"] {
        if m == attr.to_lower() { return true }
    }
    false
}

fn same(kind: string, have: string, want: string) -> bool {
    if kind == "flags" {
        let h: List[string] = []
        for p in have.split(",") { if p.trim() != "" { h.push(p.trim().to_lower()) } }
        let w: List[string] = []
        for p in want.split(",") { if p.trim() != "" { w.push(p.trim().to_lower()) } }
        if h.len() != w.len() { return false }
        for x in w { if !h.contains(x) { return false } }
        return true
    }
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

// 'ABSENT', or a JSON object of the attributes this step cares about.
//
// Two reads, not one. GetCollection() yields raw Microsoft.Web.Administration
// elements, which do NOT expose their attributes as PowerShell properties —
// only GetAttributeValue works, and that returns an enum's ordinal rather than
// its schema name. So the element is found by key in the collection, then read
// back through a filter that addresses it, because a Get-WebConfiguration
// result IS provider-wrapped and renders an enum as its name.
fn probe(params: Value, spec: CollectionSpec) -> Result[string, string] {
    let get_coll = if spec.collection == "" { "$s.GetCollection()" } else { "$s.GetCollection(" + common::ps_q(spec.collection) + ")" }
    let tests: List[string] = []
    let predicates = ""
    for r in key_rows(params, spec) {
        let a = r.get(0).unwrap_or("")
        let v = r.get(2).unwrap_or("")
        tests.push("[string]$_.GetAttributeValue(" + common::ps_q(a) + ") -eq " + common::ps_q(v))
        predicates = predicates + "[@" + a + "='" + common::xp(v)? + "']"
    }
    // The element's own tag is the schema's — add, error, mimeMap — so it is
    // spliced into the filter at run time rather than guessed.
    let tmpl = coll_filter(spec) + "/@TAG@" + predicates
    let reads = ""
    for r in attr_rows(params, spec) {
        let a = r.get(0).unwrap_or("")
        let qa = common::ps_q(a)
        if r.get(1).unwrap_or("") == "sym" {
            // Schema-resolved first, because an attribute name can collide with
            // a member the provider adds to its own output — an attribute
            // called `location` reads back as the -Location it was fetched
            // from. The addressed read is only the fallback.
            // Called with SPACE-separated arguments, not a parenthesised list:
            // in PowerShell `CwEnum($a, $b, $c)` passes ONE argument — the
            // three-element array — which left $name and $fallback null and
            // broke every symbol attribute at once. CwV(...) survives that only
            // because a single parenthesised expression is just an expression.
            reads = reads + "$fb=''; if ($e.Count -gt 0) {{ $fb=CwV($e[-1]." + a + ") }}; " +
                "$o[" + qa + "]=(CwEnum $m[-1] " + qa + " $fb); "
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
        "$tag = [string]$m[-1].ElementTagName; " +
        "$f = (" + common::ps_q(tmpl) + ").Replace('@TAG@', $tag); " +
        "$e = @(); try {{ $e = @(Get-WebConfiguration" + spec.scope + " -Filter $f) }} catch {{ }}; " +
        "$o=@{{}}; $o['__tag']=$tag; " + reads +
        "[pscustomobject]$o | ConvertTo-Json -Compress }} }}")
}

// The XPath addressing this resource's element inside its collection. The tag
// is the schema's — add, error, mimeMap, rewriteMap — so it comes from the
// probe rather than being guessed.
fn element_filter(params: Value, spec: CollectionSpec) -> Result[string, string] {
    let tag = common::get_str(json::parse(probe(params, spec)?)?, "__tag")
    if tag == "" { return Err("could not read the element's tag name") }
    let out = coll_filter(spec) + "/" + tag
    for r in key_rows(params, spec) {
        out = out + "[@" + r.get(0).unwrap_or("") + "='" + common::xp(r.get(2).unwrap_or(""))? + "']"
    }
    Ok(out)
}

fn check(params: Value, spec: CollectionSpec) -> Result[CheckResult, string] {
    let st = probe(params, spec)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let have = json::parse(st)?
    for r in attr_rows(params, spec) {
        let a = r.get(0).unwrap_or("")
        if shadowed(a) { continue }
        if !same(r.get(1).unwrap_or(""), common::get_str(have, a), r.get(2).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value, spec: CollectionSpec) -> Result[ApplyResult, string] {
    let st = probe(params, spec)?
    let filter = common::ps_q(coll_filter(spec))
    let at = ps_hash(key_rows(params, spec))
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing element from " + coll_filter(spec))
        common::ps_run("Remove-WebConfigurationProperty" + spec.scope + " -Filter " + filter +
            " -Name '.' -AtElement " + at)?
        return Ok(ApplyResult::Success)
    }
    if st == "ABSENT" {
        log::info("adding element to " + coll_filter(spec))
        common::ps_run("Add-WebConfigurationProperty" + spec.scope + " -Filter " + filter +
            " -Name '.' -Value " + ps_hash(key_rows(params, spec).concat(attr_rows(params, spec))))?
        return Ok(ApplyResult::Success)
    }
    // The element is there: set the attributes that differ on it in place.
    // Remove-and-re-add would also work for an element this level owns, but
    // it moves the element to the end of the collection, which matters
    // wherever order does — handlers, rewrite rules. Whether an override of an
    // entry the location merely INHERITS converges has not been exercised by
    // a test; the entries the suite covers are ones the location owns.
    let have = json::parse(st)?
    let elem = element_filter(params, spec)?
    let script = ""
    for r in attr_rows(params, spec) {
        let a = r.get(0).unwrap_or("")
        let kind = r.get(1).unwrap_or("")
        let want = r.get(2).unwrap_or("")
        // A shadowed attribute cannot be read, so it is always written.
        if !shadowed(a) && same(kind, common::get_str(have, a), want) { continue }
        script = script + "Set-WebConfigurationProperty" + spec.scope + " -Filter " + common::ps_q(elem) +
            " -Name " + common::ps_q(a) + " -Value " + ps_literal(kind, want) + "; "
    }
    if script == "" { return Ok(ApplyResult::Success) }
    log::info("updating element in " + coll_filter(spec))
    common::ps_run(script)?
    Ok(ApplyResult::Success)
}
