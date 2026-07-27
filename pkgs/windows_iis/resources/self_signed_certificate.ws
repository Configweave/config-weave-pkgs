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
// A self-signed certificate for a set of DNS names.
//
// It converges on "the store holds an unexpired certificate for these names",
// not on "create a certificate". A resource that minted one every run would
// leave a pile of certificates behind and move the thumbprint out from under
// every binding pointing at it. renew_before is what turns that into a
// rollover: once the certificate is inside that window of expiring, the next
// run replaces it.
// ---------------------------------------------------------------------------

fn store_path(params: Value) -> Result[string, string] {
    let s = param_str(params, "store", "my")
    if s == "my" { return Ok("Cert:\\LocalMachine\\My") }
    if s == "web_hosting" { return Ok("Cert:\\LocalMachine\\WebHosting") }
    Err("invalid 'store' value '" + s + "' (expected :my or :web_hosting)")
}

fn dns_names(params: Value) -> Result[List[string], string] {
    let names = param_list(params, "dns_names")
    if names.is_empty() { return Err("'dns_names' must name at least one host") }
    Ok(names)
}

// New-SelfSignedCertificate builds the subject from the first DNS name, so
// that is what identifies the certificate afterwards.
fn subject(params: Value) -> Result[string, string] {
    Ok("CN=" + dns_names(params)?.get(0).unwrap_or(""))
}

fn matcher(params: Value) -> Result[string, string] {
    Ok("$_.Subject -eq " + ps_q(subject(params)?))
}

// Certificates matching the subject that are still valid for at least
// renew_before.
fn live_count(params: Value) -> Result[int, string] {
    let renew_secs = param_int(params, "renew_before", 0) / 1000000000
    let out = ps_out("@(Get-ChildItem -Path " + ps_q(store_path(params)?) +
        " | Where-Object {{ " + matcher(params)? + " -and $_.NotAfter -gt (Get-Date).AddSeconds(" +
        itoa(renew_secs) + ") }}).Count")?
    if let Some(n) = out.parse_int() { return Ok(n) }
    Err("could not read the certificate store: " + out)
}

fn any_count(params: Value) -> Result[int, string] {
    let out = ps_out("@(Get-ChildItem -Path " + ps_q(store_path(params)?) +
        " | Where-Object {{ " + matcher(params)? + " }}).Count")?
    if let Some(n) = out.parse_int() { return Ok(n) }
    Err("could not read the certificate store: " + out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    if want_present(params)? {
        if live_count(params)? > 0 { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if any_count(params)? > 0 { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let store = store_path(params)?
    if !want_present(params)? {
        if any_count(params)? == 0 { return Ok(ApplyResult::Success) }
        // -DeleteKey, not -Force: Remove-Item ignores -Force in the Cert:
        // drive, so without it every renewal orphaned a private key blob. It
        // needs an explicit -Path: -DeleteKey is a dynamic parameter of the
        // certificate provider and does not bind through a pipe.
        log::info("removing self-signed certificates for " + subject(params)?)
        ps_run("Get-ChildItem -Path " + ps_q(store) + " | Where-Object {{ " + matcher(params)? +
            " }} | ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}")?
        return Ok(ApplyResult::Success)
    }
    if live_count(params)? > 0 { return Ok(ApplyResult::Success) }
    let names: List[string] = []
    for n in dns_names(params)? { names.push(ps_q(n)) }
    let friendly = param_str(params, "friendly_name", "")
    let friendly_arg = if friendly == "" { "" } else { " -FriendlyName " + ps_q(friendly) }
    log::info("creating a self-signed certificate for " + subject(params)?)
    // New-SelfSignedCertificate only accepts Cert:\\CurrentUser\\My or
    // Cert:\\LocalMachine\\My — it documents no other store — so a certificate
    // destined for WebHosting is created in My and then moved with an
    // export/import round trip. Move-Item cannot be used: it relocates the
    // certificate but not its private key.
    let create = "New-SelfSignedCertificate -DnsName " + names.join(",") +
        " -CertStoreLocation 'Cert:\\LocalMachine\\My'" +
        " -KeyLength " + itoa(param_int(params, "key_length", 2048)) +
        " -NotAfter (Get-Date).AddDays(" + itoa(param_int(params, "valid_days", 365)) + ")" +
        friendly_arg
    // Any predecessor goes first, so the store does not accumulate one dead
    // certificate per renewal.
    let purge = "Get-ChildItem -Path " + ps_q(store) + " | Where-Object {{ " + matcher(params)? +
        " }} | ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}; "
    if store == "Cert:\\LocalMachine\\My" {
        ps_run(purge + create + " | Out-Null")?
        return Ok(ApplyResult::Success)
    }
    ps_run(
        purge +
        "Get-ChildItem -Path 'Cert:\\LocalMachine\\My' | Where-Object {{ " + matcher(params)? +
        " }} | ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}; " +
        "$c = " + create + "; " +
        "$pfx = Join-Path $env:TEMP ('cw-' + $c.Thumbprint + '.pfx'); " +
        "$pw = ConvertTo-SecureString -String ([guid]::NewGuid().ToString()) -AsPlainText -Force; " +
        "Export-PfxCertificate -Cert $c -FilePath $pfx -Password $pw | Out-Null; " +
        "Import-PfxCertificate -FilePath $pfx -CertStoreLocation " + ps_q(store) +
        " -Password $pw -Exportable | Out-Null; " +
        "Remove-Item -LiteralPath $pfx -Force; " +
        "Get-ChildItem -Path 'Cert:\\LocalMachine\\My' | " +
        "Where-Object {{ $_.Thumbprint -eq $c.Thumbprint }} | " +
        "ForEach-Object {{ Remove-Item -Path $_.PSPath -DeleteKey }}")?
    Ok(ApplyResult::Success)
}
