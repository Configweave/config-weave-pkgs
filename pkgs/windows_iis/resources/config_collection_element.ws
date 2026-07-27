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
                if let Some(s) = v.as_string() { out.push([name, ps_q(s), s]) }
                else if let Some(i) = v.as_int() { out.push([name, itoa(i), itoa(i)]) }
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
    let f = param_str(params, "filter", "")
    if f == "" { return Err("missing 'filter' parameter") }
    Ok(f)
}

fn coll_filter(params: Value) -> Result[string, string] {
    let coll = param_str(params, "collection_name", "")
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
    let coll = param_str(params, "collection_name", "")
    let get_coll = if coll == "" { "$s.GetCollection()" } else { "$s.GetCollection(" + ps_q(coll) + ")" }
    let tests: List[string] = []
    for p in key_pairs(params)? {
        tests.push("[string]$_.GetAttributeValue(" + ps_q(p.get(0).unwrap_or("")) + ") -eq " +
            ps_q(p.get(2).unwrap_or("")))
    }
    let predicates = ""
    for p in key_pairs(params)? {
        predicates = predicates + "[@" + p.get(0).unwrap_or("") + "='" +
            xp(p.get(2).unwrap_or(""))? + "']"
    }
    let tmpl = coll_filter(params)? + "/@TAG@" + predicates
    let reads = ""
    for p in map_pairs(params, "attributes")? {
        let a = ps_q(p.get(0).unwrap_or(""))
        reads = reads + "$o[" + a + "]=CwV($m[-1].GetAttributeValue(" + a + ")); "
    }
    ps_out(
        // No top-level `return`: PowerShell -Command treats one as a
        // script-level exit and the caller sees a failure with an empty stderr.
        "$s = $null; try {{ $s = Get-WebConfiguration" + scope_delegated(params)? + " -Filter " +
        ps_q(section(params)?) + " }} catch {{ }}; " +
        "if ($null -eq $s) {{ 'ABSENT' }} else {{ " +
        "$m = @(" + get_coll + " | Where-Object {{ " + tests.join(" -and ") + " }}); " +
        "if ($m.Count -eq 0) {{ 'ABSENT' }} else {{ $o=@{{}}; " +
        "$o['__tag']=[string]$m[-1].ElementTagName; " + reads +
        "[pscustomobject]$o | ConvertTo-Json -Compress }} }}")
}

// The XPath addressing this element inside its collection. The tag is the
// schema's — add, error, mimeMap — so it comes from the probe.
fn element_filter(params: Value) -> Result[string, string] {
    let tag = get_str(json::parse(probe(params)?)?, "__tag")
    if tag == "" { return Err("could not read the element's tag name") }
    let out = coll_filter(params)? + "/" + tag
    for p in key_pairs(params)? {
        out = out + "[@" + p.get(0).unwrap_or("") + "='" + xp(p.get(2).unwrap_or(""))? + "']"
    }
    Ok(out)
}

fn same(have: string, want: string) -> bool {
    have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let have = json::parse(st)?
    for p in map_pairs(params, "attributes")? {
        let a = p.get(0).unwrap_or("")
        if !same(get_str(have, a), p.get(2).unwrap_or("")) { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let st = probe(params)?
    let scope = scope_delegated(params)?
    let filter = ps_q(coll_filter(params)?)
    let at = ps_hash(key_pairs(params)?)
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
        if same(get_str(have, a), p.get(2).unwrap_or("")) { continue }
        script = script + "Set-WebConfigurationProperty" + scope + " -Filter " + ps_q(elem) +
            " -Name " + ps_q(a) + " -Value " + p.get(1).unwrap_or("") + "; "
    }
    if script == "" { return Ok(ApplyResult::Success) }
    log::info("updating element in " + coll_filter(params)?)
    ps_run(script)?
    Ok(ApplyResult::Success)
}
