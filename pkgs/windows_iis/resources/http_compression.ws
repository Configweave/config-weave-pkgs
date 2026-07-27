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
// Server-wide compression. This section is not delegated, so there is no
// site, path or store to scope it with.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    Ok("system.webServer/httpCompression")
}

fn scope(params: Value) -> Result[string, string] { scope_apphost(params) }

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["directory", "directory", "str"],
        ["min_file_size_for_comp", "minFileSizeForComp", "int"],
        ["do_disk_space_limiting", "doDiskSpaceLimiting", "bool"],
        ["max_disk_space_usage", "maxDiskSpaceUsage", "int"],
        ["no_compression_for_proxies", "noCompressionForProxies", "bool"],
        ["no_compression_for_http10", "noCompressionForHttp10", "bool"],
        ["no_compression_for_range", "noCompressionForRange", "bool"],
        ["send_cache_headers", "sendCacheHeaders", "bool"],
        ["cache_control_header", "cacheControlHeader", "str"],
        ["expires_header", "expiresHeader", "str"],
    ] }

// [param, symbol value, IIS token]
fn sym_map() -> List[List[string]] { [] }

// Checked before apply mutates anything.
fn precondition(params: Value) -> Result[unit, string] {
    Ok(())
}

// Run after apply changes something; a no-op for most sections.
fn postcondition(params: Value) -> Result[unit, string] {
    Ok(())
}

// ---------------------------------------------------------------------------
// Section machinery — also byte-identical across the section scripts. Each of
// those declares only section(), scope(), attrs() and sym_map(); everything
// below is the same read-diff-write over whatever they name.
// ---------------------------------------------------------------------------

// The IIS spelling of a symbol value. Symbols are validated against the
// declared set by config-weave, so all that is left here is spelling: WCL
// symbols cannot contain a dot, a hyphen or a capital, so the tokens are
// written out rather than derived.
fn iis_symbol(name: string, v: string) -> string {
    for row in sym_map() {
        if row.get(0).unwrap_or("") == name && row.get(1).unwrap_or("") == v {
            return row.get(2).unwrap_or("")
        }
    }
    v
}

// The text IIS stores for a param the step supplied, or None when the step
// left it alone. An explicit empty string counts as "leave it alone" too:
// every optional string param here carries default = "", so it is always
// present in the map and absence cannot be the signal.
fn desired(params: Value, name: string, kind: string) -> Option[string] {
    if !has(params, name) { return None }
    if kind == "bool" {
        if param_bool(params, name, false) { return Some("true") }
        return Some("false")
    }
    if kind == "int" { return Some(itoa(param_int(params, name, 0))) }
    if kind == "dur" { return Some(hms(param_int(params, name, 0))) }
    if kind == "dur_sec" { return Some(itoa(param_int(params, name, 0) / 1000000000)) }
    if kind == "dur_ms" { return Some(itoa(param_int(params, name, 0) / 1000000)) }
    if kind == "flags" || kind == "vlist" { return Some(param_list(params, name).join(",")) }
    let raw = param_str(params, name, "")
    if raw == "" { return None }
    if kind == "sym" { return Some(iis_symbol(name, raw)) }
    Some(raw)
}

// The [param, attribute, kind, desired text] rows this step asks for.
fn wanted(params: Value) -> List[List[string]] {
    let out: List[List[string]] = []
    for a in attrs() {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        if let Some(text) = desired(params, name, kind) {
            out.push([name, a.get(1).unwrap_or(""), kind, text])
        }
    }
    out
}

// One PowerShell round trip reads every attribute the step named — and only
// those: reading an attribute whose feature is not installed errors, and a
// step that never mentions it should not have to care.
fn probe(params: Value, rows: List[List[string]]) -> Result[Value, string] {
    let scope = scope(params)?
    let filter = ps_q(section(params)?)
    // Reads go through the section element rather than
    // Get-WebConfigurationProperty: that cmdlet hands back the raw value of an
    // enum attribute — sslFlags reads as 0, not None — while the provider
    // renders the schema name when the attribute is reached as a property.
    // Every symbol param in this package compares against the name.
    let reads = ""
    for r in rows {
        let name = ps_q(r.get(0).unwrap_or(""))
        let attr = r.get(1).unwrap_or("")
        reads = reads + "$o[" + name + "]=''; try {{ "
        if r.get(2).unwrap_or("") == "vlist" {
            reads = reads + "$o[" + name + "]=((@($s." + attr +
                ".Collection | ForEach-Object {{ [string]$_.value }})) -join ',')"
        } else {
            reads = reads + "$o[" + name + "]=CwV($s." + attr + ")"
        }
        reads = reads + " }} catch {{ }}; "
    }
    // A -Location for a site that does not exist yet cannot be read at all, so
    // the whole section read is guarded: every attribute then reports empty,
    // which is drift, which is the truth on a first run.
    json::parse(ps_out(
        "$o=@{{}}; $s=$null; try {{ $s = Get-WebConfiguration" + scope + " -Filter " + filter +
        " }} catch {{ }}; if ($null -ne $s) {{ " + reads + "}}; " +
        "[pscustomobject]$o | ConvertTo-Json -Compress")?)
}

// IIS reports a flags attribute in its own order and spacing, and a symbol
// one with the schema's capitalisation, so neither is compared as text.
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

// IIS's schema rejects a string where it wants a number or a flag, so a value
// is emitted as the PowerShell literal its type needs.
fn ps_value(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    if kind == "int" || kind == "dur_sec" || kind == "dur_ms" { return want }
    ps_q(want)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let rows = wanted(params)
    if rows.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    let have = probe(params, rows)?
    for r in rows {
        let kind = r.get(2).unwrap_or("")
        if !same(kind, get_str(have, r.get(0).unwrap_or("")), r.get(3).unwrap_or("")) {
            return Ok(CheckResult::NotConfigured)
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    precondition(params)?
    let rows = wanted(params)
    if rows.is_empty() { return Ok(ApplyResult::Success) }
    let have = probe(params, rows)?
    let scope = scope(params)?
    let filter = ps_q(section(params)?)
    let script = ""
    for r in rows {
        let name = r.get(0).unwrap_or("")
        let attr = r.get(1).unwrap_or("")
        let kind = r.get(2).unwrap_or("")
        let want = r.get(3).unwrap_or("")
        if same(kind, get_str(have, name), want) { continue }
        log::info("setting " + attr + " = " + want)
        if kind == "vlist" {
            // Set-WebConfigurationProperty on a collection name REPLACES the
            // collection, which is what an ordered list needs: appending
            // would leave the inherited entries in front.
            let parts: List[string] = []
            for v in want.split(",") { if v != "" { parts.push("@{{value=" + ps_q(v) + "}}") } }
            script = script + "Set-WebConfigurationProperty" + scope + " -Filter " + filter +
                " -Name " + ps_q(attr) + " -Value @(" + parts.join(",") + "); "
        } else {
            script = script + "Set-WebConfigurationProperty" + scope + " -Filter " + filter +
                " -Name " + ps_q(attr) + " -Value " + ps_value(kind, want) + "; "
        }
    }
    if script == "" { return Ok(ApplyResult::Success) }
    ps_run(script)?
    postcondition(params)?
    Ok(ApplyResult::Success)
}
