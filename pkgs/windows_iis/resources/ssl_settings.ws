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
// The "SSL Settings" page: system.webServer/security/access sslFlags.
//
// IIS stores one comma-separated flags attribute, but a playbook thinks in
// three independent switches, so this reads the current flags, replaces only
// the bits the step named, and writes the set back. A step that mentions
// require_ssl therefore does not silently clear an inherited SslRequireCert.
// ---------------------------------------------------------------------------

fn section() -> string { "system.webServer/security/access" }

fn flag_set(text: string) -> List[string] {
    let out: List[string] = []
    for p in text.split(",") {
        let f = p.trim()
        if f != "" && f.to_lower() != "none" { out.push(f) }
    }
    out
}

fn without(flags: List[string], drop: string) -> List[string] {
    let out: List[string] = []
    for f in flags { if f.to_lower() != drop.to_lower() { out.push(f) } }
    out
}

fn client_certificates(params: Value) -> Result[string, string] {
    let v = param_str(params, "client_certificates", "")
    if v == "" { return Ok("") }
    if v == "ignore" || v == "accept" || v == "require" { return Ok(v) }
    Err("invalid 'client_certificates' value '" + v + "'")
}

// The flags the step wants, folded into whatever is already there.
fn wanted_flags(params: Value, current: string) -> Result[string, string] {
    let flags = flag_set(current)
    if has(params, "require_ssl") {
        flags = without(flags, "Ssl")
        if param_bool(params, "require_ssl", false) { flags.push("Ssl") }
    }
    if has(params, "require_128bit") {
        flags = without(flags, "Ssl128")
        if param_bool(params, "require_128bit", false) { flags.push("Ssl128") }
    }
    let cc = client_certificates(params)?
    if cc != "" {
        // SslRequireCert only means anything alongside SslNegotiateCert, so
        // the two move together.
        flags = without(without(flags, "SslNegotiateCert"), "SslRequireCert")
        if cc == "accept" { flags.push("SslNegotiateCert") }
        if cc == "require" {
            flags.push("SslNegotiateCert")
            flags.push("SslRequireCert")
        }
    }
    if flags.is_empty() { return Ok("None") }
    flags.sort()
    Ok(flags.join(","))
}

// Through the section element, not Get-WebConfigurationProperty: the cmdlet
// hands back the raw flags number ("0"), which would then be folded into the
// set as if it were a flag name and rejected by the schema. Guarded because a
// -Location for a site that does not exist yet cannot be read at all.
fn current_flags(params: Value) -> Result[string, string] {
    ps_out("$s=$null; try {{ $s = Get-WebConfiguration" + scope_delegated(params)? + " -Filter " +
        ps_q(section()) + " }} catch {{ }}; " +
        "if ($null -eq $s) {{ 'None' }} else {{ CwV($s.sslFlags) }}")
}

fn normalized(text: string) -> string {
    let flags = flag_set(text)
    if flags.is_empty() { return "None" }
    let lower: List[string] = []
    for f in flags { lower.push(f.to_lower()) }
    lower.sort()
    lower.join(",")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let now = current_flags(params)?
    if normalized(now) == normalized(wanted_flags(params, now)?) {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let now = current_flags(params)?
    let want = wanted_flags(params, now)?
    if normalized(now) == normalized(want) { return Ok(ApplyResult::Success) }
    log::info("setting sslFlags = " + want)
    ps_run("Set-WebConfigurationProperty" + scope_delegated(params)? + " -Filter " +
        ps_q(section()) + " -Name 'sslFlags' -Value " + ps_q(want))?
    Ok(ApplyResult::Success)
}
