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
// An application under a site: the application element plus its root virtual
// directory, which is where physicalPath actually lives.
// ---------------------------------------------------------------------------

fn site_filter(params: Value) -> Result[string, string] {
    let site = param_str(params, "site", "")
    if site == "" { return Err("missing 'site' parameter") }
    Ok("system.applicationHost/sites/site[@name='" + xp(site)? + "']")
}

// IIS stores an application path with a leading slash and no trailing one.
fn app_path(params: Value) -> Result[string, string] {
    let p = param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    let s = if p.starts_with("/") { p } else { "/" + p }
    if s.len() > 1 && s.ends_with("/") { return Ok(s.slice(0, s.len() - 1)) }
    Ok(s)
}

fn app_filter(params: Value) -> Result[string, string] {
    Ok(site_filter(params)? + "/application[@path='" + xp(app_path(params)?)? + "']")
}

fn vdir_filter(params: Value) -> Result[string, string] {
    Ok(app_filter(params)? + "/virtualDirectory[@path='/']")
}

fn norm_path(p: string) -> string {
    let s = p.replace("/", "\\").to_lower()
    if s.len() > 1 && s.ends_with("\\") { return s.slice(0, s.len() - 1) }
    s
}

fn same_path(a: string, b: string) -> bool { norm_path(a) == norm_path(b) }

// [param, IIS attribute] set on the application element itself.
fn attrs() -> List[List[string]] { [
        ["app_pool", "applicationPool", "str"],
        ["enabled_protocols", "enabledProtocols", "str"],
        ["preload_enabled", "preloadEnabled", "bool"],
        ["service_auto_start_enabled", "serviceAutoStartEnabled", "bool"],
        ["service_auto_start_provider", "serviceAutoStartProvider", "str"],
    ] }

fn desired(params: Value, name: string, kind: string) -> Option[string] {
    if !has(params, name) { return None }
    if kind == "bool" {
        if param_bool(params, name, false) { return Some("true") }
        return Some("false")
    }
    let raw = param_str(params, name, "")
    if raw == "" { return None }
    Some(raw)
}

fn ps_value(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    ps_q(want)
}

fn exists(params: Value) -> Result[bool, string] {
    let st = ps_out("if (@(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        ps_q(app_filter(params)?) + ").Count -gt 0) {{ 'YES' }} else {{ 'NO' }}")?
    Ok(st == "YES")
}

fn probe(params: Value) -> Result[Value, string] {
    let script = "$o=@{{}}; $o['physical_path']=CwV(Get-WebConfigurationProperty " +
        "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + ps_q(vdir_filter(params)?) +
        " -Name 'physicalPath'); "
    for a in attrs() {
        let name = a.get(0).unwrap_or("")
        script = script + "$o[" + ps_q(name) + "]=CwV(Get-WebConfigurationProperty " +
            "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + ps_q(app_filter(params)?) +
            " -Name " + ps_q(a.get(1).unwrap_or("")) + "); "
    }
    json::parse(ps_out(script + "[pscustomobject]$o | ConvertTo-Json -Compress")?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let there = exists(params)?
    if !want_present(params)? {
        if there { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // As for a site: a missing physical_path is only an error at apply time,
    // because a check runs before any sibling step has applied.
    if !there { return Ok(CheckResult::NotConfigured) }
    let s = probe(params)?
    let path = param_str(params, "physical_path", "")
    if path != "" && !same_path(get_str(s, "physical_path"), path) { return Ok(CheckResult::NotConfigured) }
    for a in attrs() {
        let name = a.get(0).unwrap_or("")
        if let Some(want) = desired(params, name, a.get(2).unwrap_or("")) {
            if get_str(s, name).to_lower() != want.to_lower() { return Ok(CheckResult::NotConfigured) }
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let path = app_path(params)?
    if !want_present(params)? {
        if !exists(params)? { return Ok(ApplyResult::Success) }
        log::info("removing application " + path)
        ps_run("Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            ps_q(site_filter(params)?) + " -Name '.' -AtElement @{{path=" + ps_q(path) + "}}")?
        return Ok(ApplyResult::Success)
    }
    let physical = param_str(params, "physical_path", "")
    if !exists(params)? {
        if physical == "" {
            return Err("application '" + path +
                "' does not exist and no 'physical_path' was given to create it")
        }
        log::info("creating application " + path + " at " + physical)
        ps_run(
            "if (-not (Test-Path -LiteralPath " + ps_q(physical) + ")) {{ " +
            "New-Item -ItemType Directory -Path " + ps_q(physical) + " | Out-Null }}; " +
            // As for a site: whether the application's root virtual
            // directory is materialised with it depends on
            // virtualDirectoryDefaults, so handle both.
            "Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            ps_q(site_filter(params)?) + " -Name '.' -Value @{{path=" + ps_q(path) + "}}; " +
            "$vd = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            ps_q(app_filter(params)? + "/virtualDirectory") + " | Where-Object {{ [string]$_.GetAttributeValue('path') -eq '/' }}); " +
            "if ($vd.Count -eq 0) {{ Add-WebConfigurationProperty " +
            "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + ps_q(app_filter(params)?) +
            " -Name '.' -Value @{{path='/'; physicalPath=" + ps_q(physical) + "}} }} " +
            "else {{ Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            ps_q(vdir_filter(params)?) + " -Name 'physicalPath' -Value " + ps_q(physical) + " }}")?
    }
    let s = probe(params)?
    let script = ""
    if physical != "" && !same_path(get_str(s, "physical_path"), physical) {
        script = script +
            "if (-not (Test-Path -LiteralPath " + ps_q(physical) + ")) {{ " +
            "New-Item -ItemType Directory -Path " + ps_q(physical) + " | Out-Null }}; " +
            "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            ps_q(vdir_filter(params)?) + " -Name 'physicalPath' -Value " + ps_q(physical) + "; "
    }
    for a in attrs() {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        if let Some(want) = desired(params, name, kind) {
            if get_str(s, name).to_lower() == want.to_lower() { continue }
            script = script +
                "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                ps_q(app_filter(params)?) + " -Name " + ps_q(a.get(1).unwrap_or("")) +
                " -Value " + ps_value(kind, want) + "; "
        }
    }
    if script != "" {
        log::info("updating application " + path)
        ps_run(script)?
    }
    Ok(ApplyResult::Success)
}
