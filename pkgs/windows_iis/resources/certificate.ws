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
// A PFX imported into a LocalMachine certificate store.
//
// Identity is the thumbprint when one is given — the only identity that
// cannot match the wrong certificate — and the subject otherwise. An import
// only happens when nothing already matches, so re-running never produces a
// second copy and never rotates a certificate a binding is pointing at.
// ---------------------------------------------------------------------------

fn store_path(params: Value) -> Result[string, string] {
    let s = param_str(params, "store", "my")
    if s == "my" { return Ok("Cert:\\LocalMachine\\My") }
    if s == "web_hosting" { return Ok("Cert:\\LocalMachine\\WebHosting") }
    Err("invalid 'store' value '" + s + "' (expected :my or :web_hosting)")
}

fn norm_thumb(t: string) -> string { t.replace(" ", "").replace(":", "").to_upper() }

// The Where-Object test that picks this resource's certificate out of the
// store.
fn matcher(params: Value) -> Result[string, string] {
    let thumb = param_str(params, "thumbprint", "")
    if thumb != "" {
        return Ok("$_.Thumbprint -eq " + ps_q(norm_thumb(thumb)))
    }
    let subject = param_str(params, "subject", "")
    if subject == "" {
        return Err("give either 'thumbprint' or 'subject' so the certificate can be identified")
    }
    Ok("$_.Subject -eq " + ps_q(subject))
}

fn count(params: Value) -> Result[int, string] {
    let out = ps_out("@(Get-ChildItem -Path " + ps_q(store_path(params)?) +
        " | Where-Object {{ " + matcher(params)? + " }}).Count")?
    if let Some(n) = out.parse_int() { return Ok(n) }
    Err("could not read the certificate store: " + out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let there = count(params)? > 0
    if want_present(params)? {
        if there { return Ok(CheckResult::AlreadyConfigured) }
        if param_str(params, "pfx_path", "") == "" {
            return Err("no matching certificate in the store and no 'pfx_path' was given to import one")
        }
        return Ok(CheckResult::NotConfigured)
    }
    if there { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let store = store_path(params)?
    if !want_present(params)? {
        if count(params)? == 0 { return Ok(ApplyResult::Success) }
        // -DeleteKey, not -Force: in the Cert: drive Remove-Item honours only
        // DeleteKey/Path/WhatIf/Confirm and IGNORES everything else, so -Force
        // did nothing and the private key was left behind in MachineKeys.
        // It has to be passed with an explicit -Path: -DeleteKey is a dynamic
        // parameter of the certificate provider, and piping gives PowerShell no
        // path to resolve it against.
        log::info("removing certificate from " + store)
        ps_run("Get-ChildItem -Path " + ps_q(store) + " | Where-Object {{ " + matcher(params)? +
            " }} | ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}")?
        return Ok(ApplyResult::Success)
    }
    if count(params)? > 0 { return Ok(ApplyResult::Success) }
    let source = param_str(params, "pfx_path", "")
    if source == "" {
        return Err("no matching certificate in the store and no 'pfx_path' was given to import one")
    }
    // A URL is fetched host-side so the guest needs no network stack of its
    // own, the same way windows_installers.msi_package handles a remote MSI.
    let local = if source.starts_with("http://") || source.starts_with("https://") {
        let tmp = fs::temp_file()?
        log::info("downloading " + source)
        http::download(source, tmp, Value::Null)?
        tmp
    } else {
        source
    }
    let password = param_str(params, "password", "")
    let pw = if password == "" {
        ""
    } else {
        " -Password (ConvertTo-SecureString " + ps_q(password) + " -AsPlainText -Force)"
    }
    let exportable = if param_bool(params, "exportable", false) { " -Exportable" } else { "" }
    log::info("importing certificate into " + store)
    ps_run("Import-PfxCertificate -FilePath " + ps_q(local) + " -CertStoreLocation " +
        ps_q(store) + pw + exportable + " | Out-Null")?
    Ok(ApplyResult::Success)
}
