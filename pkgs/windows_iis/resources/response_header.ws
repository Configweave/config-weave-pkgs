use value
use shell
use json
use log
use fs
use http
use registry

// ---------------------------------------------------------------------------
// Shared IIS helpers — byte-identical in every script in this package.
//
// wscript has no script-to-script imports yet (config-weave compiles `lib/`
// but cannot resolve it), so this block is duplicated rather than shared.
// Keep the copies identical; moving to lib/ is then a mechanical delete.
//
// Everything goes through PowerShell's WebAdministration module rather than
// editing applicationHost.config directly. IIS owns the schema validation,
// the collection merge semantics and the config file locking, none of which a
// hand-rolled XML writer gets right. The cost is that the target needs the
// IIS management scripting tools (the :scripting_tools role service).
// ---------------------------------------------------------------------------

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
    fallback
}

fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn param_list(params: Value, key: string) -> List[string] {
    let items: List[string] = []
    if let Some(v) = params.get(key) {
        if let Some(xs) = v.as_list() {
            for x in xs { if let Some(s) = x.as_string() { items.push(s) } }
        }
    }
    items
}

// A param the step omitted is absent from the map, and that absence means
// "leave this setting alone" — the only way a bool or int param can say so,
// since a declared default would instead mean "set it to false" / "set it to
// 0".
fn has(params: Value, key: string) -> bool {
    if let Some(v) = params.get(key) { return !v.is_null() }
    false
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

fn itoa(n: int) -> string { json::to_string(Value::Int(n)) }

fn pad2(n: int) -> string {
    let s = itoa(n)
    if s.len() < 2 { return "0" + s }
    s
}

// A duration param arrives as base nanoseconds. IIS stores a TimeSpan and
// hands it back through .NET's default format, which is "[d.]hh:mm:ss" — a day
// or more gets a leading "1." and the hours restart. Emitting a bare
// "29:00:00" therefore never compares equal to the "1.05:00:00" that comes
// back, and the attribute re-applies for ever. IIS's own default pool
// recycling interval is 29 hours, so this is a real case, not a corner one.
fn hms(ns: int) -> string {
    let secs = ns / 1000000000
    let days = secs / 86400
    let rest = secs % 86400
    let clock = pad2(rest / 3600) + ":" + pad2((rest % 3600) / 60) + ":" + pad2(rest % 60)
    if days > 0 { return itoa(days) + "." + clock }
    clock
}

// Import-Module is explicit so a machine without the scripting tools fails
// with "the specified module was not loaded" rather than "the term
// Get-WebConfigurationProperty is not recognized". CwV flattens whatever a
// configuration read hands back — a ConfigurationAttribute, a raw value, a
// TimeSpan or a flags enum — into the text this package compares against.
fn ps_head() -> string {
    "$ErrorActionPreference='Stop'; Import-Module WebAdministration; " +
    "function CwV($x) {{ " +
    "if ($null -eq $x) {{ return '' }}; " +
    "if ($x.PSObject.Properties.Name -contains 'Value') {{ $x = $x.Value }}; " +
    "if ($null -eq $x) {{ return '' }}; " +
    "if ($x -is [bool]) {{ if ($x) {{ return 'true' }} else {{ return 'false' }} }}; " +
    "if ($x -is [timespan]) {{ return $x.ToString() }}; " +
    "return ([string]$x) }}; " +
    "function CwEnum($el, $name, $fallback) {{ try {{ " +
    "$v = $el.GetAttributeValue($name); " +
    "$sch = $el.Schema.AttributeSchemas[$name]; " +
    "if ($null -ne $sch) {{ foreach ($ev in $sch.EnumValues) {{ " +
    "if ([int]$ev.Value -eq [int]$v) {{ return [string]$ev.Name }} }} }} " +
    "}} catch {{ }}; return $fallback }}; "
}

fn ps_out(script: string) -> Result[string, string] {
    let out = shell::powershell(ps_head() + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn ps_run(script: string) -> Result[unit, string] {
    let out = shell::powershell(ps_head() + script, Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(())
}

fn get_str(m: Value, key: string) -> string {
    if let Some(v) = m.get(key) { if let Some(s) = v.as_string() { return s } }
    ""
}

// -PSPath and -Location for a delegated section. Writing to
// MACHINE/WEBROOT/APPHOST under a -Location is the PowerShell spelling of
// appcmd's /commit:apphost: it reaches a section that is locked against
// web.config, which every system.webServer/security/* section is by default.
fn scope_delegated(params: Value) -> Result[string, string] {
    let site = param_str(params, "site", "")
    let path = param_str(params, "path", "")
    let store = param_str(params, "store", "apphost")
    if store == "apphost" {
        let base = " -PSPath 'MACHINE/WEBROOT/APPHOST'"
        if site == "" { return Ok(base) }
        return Ok(base + " -Location " + ps_q(site + path))
    }
    if store == "web_config" {
        if site == "" { return Err("store = :web_config needs a 'site'") }
        // The IIS provider documents backslashes throughout an IIS:\ path, so
        // the virtual path's forward slashes are converted and its leading and
        // trailing separators dropped: "/api/v2" under site "web" becomes
        // IIS:\Sites\web\api\v2, and "/" becomes IIS:\Sites\web.
        let rel = path.replace("/", "\\")
        if rel.starts_with("\\") { rel = rel.slice(1, rel.len()) }
        if rel.ends_with("\\") { rel = rel.slice(0, rel.len() - 1) }
        let full = if rel == "" { "IIS:\\Sites\\" + site } else { "IIS:\\Sites\\" + site + "\\" + rel }
        return Ok(" -PSPath " + ps_q(full))
    }
    Err("invalid 'store' value '" + store + "' (expected :apphost or :web_config)")
}

// Sections under system.applicationHost are never delegated: the site or
// pool is named in the filter's XPath instead of in a -Location.
fn scope_apphost(params: Value) -> Result[string, string] {
    Ok(" -PSPath 'MACHINE/WEBROOT/APPHOST'")
}

// The URL Rewrite section only exists once the separate module is installed,
// and a raw "filter is not a known section" from PowerShell tells nobody what
// to do about it. The rewrite resources call this before mutating anything.
fn require_rewrite() -> Result[unit, string] {
    let out = shell::powershell(
        "if (Test-Path (Join-Path $env:windir 'system32\\inetsrv\\rewrite.dll')) {{ 'YES' }} else {{ 'NO' }}",
        Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    if out.stdout.trim() == "YES" { return Ok(()) }
    Err("the URL Rewrite module is not installed; add a windows_iis.rewrite_module step first")
}

// An XPath predicate value. IIS's own escaping stops at the apostrophe, so
// so does this: a site or path holding one is rejected rather than silently
// matching the wrong element.
fn xp(s: string) -> Result[string, string] {
    if s.contains("'") { return Err("'" + s + "' contains an apostrophe, which IIS configuration XPath cannot express") }
    Ok(s)
}

// ---------------------------------------------------------------------------
// One custom response header.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/httpProtocol")
}

fn collection(params: Value) -> Result[string, string] {
    Ok("customHeaders")
}

fn scope(params: Value) -> Result[string, string] { scope_delegated(params) }

// [param, IIS attribute, kind] identifying the element
fn keys(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["name", "name", "str"],
    ])
}

// [param, IIS attribute, kind] set on the element
fn attrs(params: Value) -> Result[List[List[string]], string] {
    Ok([
        ["value", "value", "str"],
    ])
}

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

// IIS attributes this resource owns outright: written even when
// empty, so an inherited value can be cleared rather than kept.
fn always_write() -> List[string] { [] }

// Checked before apply mutates anything.
fn precondition(params: Value) -> Result[unit, string] {
    Ok(())
}

// ---------------------------------------------------------------------------
// Collection machinery — also byte-identical across the collection scripts.
// Each of those declares only section(), collection(), scope(), keys(),
// attrs() and sym_map(); everything below is the same find-by-key,
// add-or-replace, remove-by-key over whatever they name.
// ---------------------------------------------------------------------------

fn iis_symbol(name: string, v: string) -> string {
    for row in sym_map() {
        if row.get(0).unwrap_or("") == name && row.get(1).unwrap_or("") == v {
            return row.get(2).unwrap_or("")
        }
    }
    v
}

// Unlike a section attribute, an element is written whole, so an empty
// string here is a real value rather than "leave it alone" — there is no
// inherited element to leave alone.
fn text_of(params: Value, name: string, kind: string) -> string {
    if kind == "bool" {
        if param_bool(params, name, false) { return "true" }
        return "false"
    }
    if kind == "int" { return itoa(param_int(params, name, 0)) }
    if kind == "dur" { return hms(param_int(params, name, 0)) }
    if kind == "dur_sec" { return itoa(param_int(params, name, 0) / 1000000000) }
    if kind == "dur_ms" { return itoa(param_int(params, name, 0) / 1000000) }
    if kind == "flags" || kind == "vlist" { return param_list(params, name).join(",") }
    if kind == "sym" { return iis_symbol(name, param_str(params, name, "")) }
    param_str(params, name, "")
}

// [attribute, kind, text] for the rows that identify the element.
fn key_rows(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    for a in keys(params)? {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        out.push([a.get(1).unwrap_or(""), kind, text_of(params, name, kind)])
    }
    Ok(out)
}

// [attribute, kind, text] for the rows the step wants set on the element.
// Optional strings the step left empty are skipped so IIS keeps its own
// default rather than being handed "".
fn attr_rows(params: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    for a in attrs(params)? {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        if !has(params, name) { continue }
        let text = text_of(params, name, kind)
        let owned = always_write().contains(a.get(1).unwrap_or(""))
        if text == "" && !owned && (kind == "str" || kind == "sym") { continue }
        out.push([a.get(1).unwrap_or(""), kind, text])
    }
    Ok(out)
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
    ps_q(want)
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

// 'ABSENT', or a JSON object of the attributes this step cares about.
//
// Two reads, not one. GetCollection() yields raw Microsoft.Web.Administration
// elements, which do NOT expose their attributes as PowerShell properties —
// only GetAttributeValue works, and that returns an enum's ordinal rather than
// its schema name. So the element is found by key in the collection, then read
// back through a filter that addresses it, because a Get-WebConfiguration
// result IS provider-wrapped and renders an enum as its name.
fn probe(params: Value) -> Result[string, string] {
    let scope = scope(params)?
    let coll = collection(params)?
    let get_coll = if coll == "" { "$s.GetCollection()" } else { "$s.GetCollection(" + ps_q(coll) + ")" }
    let tests: List[string] = []
    let predicates = ""
    for r in key_rows(params)? {
        let a = r.get(0).unwrap_or("")
        let v = r.get(2).unwrap_or("")
        tests.push("[string]$_.GetAttributeValue(" + ps_q(a) + ") -eq " + ps_q(v))
        predicates = predicates + "[@" + a + "='" + xp(v)? + "']"
    }
    // The element's own tag is the schema's — add, error, mimeMap — so it is
    // spliced into the filter at run time rather than guessed.
    let tmpl = coll_filter(params)? + "/@TAG@" + predicates
    let reads = ""
    for r in attr_rows(params)? {
        let a = r.get(0).unwrap_or("")
        let qa = ps_q(a)
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
    ps_out(
        "$s = $null; try {{ $s = Get-WebConfiguration" + scope + " -Filter " +
        ps_q(section(params)?) + " }} catch {{ }}; " +
        "if ($null -eq $s) {{ 'ABSENT' }} else {{ " +
        "$m = @(" + get_coll + " | Where-Object {{ " + tests.join(" -and ") + " }}); " +
        "if ($m.Count -eq 0) {{ 'ABSENT' }} else {{ " +
        "$tag = [string]$m[-1].ElementTagName; " +
        "$f = (" + ps_q(tmpl) + ").Replace('@TAG@', $tag); " +
        "$e = @(); try {{ $e = @(Get-WebConfiguration" + scope + " -Filter $f) }} catch {{ }}; " +
        "$o=@{{}}; $o['__tag']=$tag; " + reads +
        "[pscustomobject]$o | ConvertTo-Json -Compress }} }}")
}

// The collection's own filter: the section itself when the section IS the
// collection, as system.webServer/handlers is, otherwise the named child.
fn coll_filter(params: Value) -> Result[string, string] {
    let coll = collection(params)?
    if coll == "" { return Ok(section(params)?) }
    Ok(section(params)? + "/" + coll)
}

// The XPath addressing this resource's element inside its collection. The tag
// is the schema's — add, error, mimeMap, rewriteMap — so it comes from the
// probe rather than being guessed.
fn element_filter(params: Value) -> Result[string, string] {
    let tag = get_str(json::parse(probe(params)?)?, "__tag")
    if tag == "" { return Err("could not read the element's tag name") }
    let out = coll_filter(params)? + "/" + tag
    for r in key_rows(params)? {
        out = out + "[@" + r.get(0).unwrap_or("") + "='" + xp(r.get(2).unwrap_or(""))? + "']"
    }
    Ok(out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let have = json::parse(st)?
    for r in attr_rows(params)? {
        let a = r.get(0).unwrap_or("")
        if shadowed(a) { continue }
        if !same(r.get(1).unwrap_or(""), get_str(have, a), r.get(2).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    precondition(params)?
    let st = probe(params)?
    let scope = scope(params)?
    let filter = ps_q(coll_filter(params)?)
    let at = ps_hash(key_rows(params)?)
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing element from " + coll_filter(params)?)
        ps_run("Remove-WebConfigurationProperty" + scope + " -Filter " + filter +
            " -Name '.' -AtElement " + at)?
        return Ok(ApplyResult::Success)
    }
    if st == "ABSENT" {
        log::info("adding element to " + coll_filter(params)?)
        ps_run("Add-WebConfigurationProperty" + scope + " -Filter " + filter +
            " -Name '.' -Value " + ps_hash(key_rows(params)?.concat(attr_rows(params)?)))?
        return Ok(ApplyResult::Success)
    }
    // The element is there: set the attributes that differ on it in place.
    // Remove-and-re-add would also work for an element this level owns, but
    // it moves the element to the end of the collection, which matters
    // wherever order does — handlers, rewrite rules. Whether an override of an
    // entry the location merely INHERITS converges has not been exercised by
    // a test; the entries the suite covers are ones the location owns.
    let have = json::parse(st)?
    let elem = element_filter(params)?
    let script = ""
    for r in attr_rows(params)? {
        let a = r.get(0).unwrap_or("")
        let kind = r.get(1).unwrap_or("")
        let want = r.get(2).unwrap_or("")
        // A shadowed attribute cannot be read, so it is always written.
        if !shadowed(a) && same(kind, get_str(have, a), want) { continue }
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " + ps_q(elem) +
            " -Name " + ps_q(a) + " -Value " + ps_literal(kind, want) + "; "
    }
    if script == "" { return Ok(ApplyResult::Success) }
    log::info("updating element in " + coll_filter(params)?)
    ps_run(script)?
    Ok(ApplyResult::Success)
}
