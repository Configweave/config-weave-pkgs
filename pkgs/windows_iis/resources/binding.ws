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
// A site binding.
//
// IIS keys a binding on the whole (protocol, address, port, host header)
// tuple — that is literally what bindingInformation is — so changing a port
// adds a binding rather than editing one. Retire the old tuple with
// ensure = :absent.
//
// The certificate is attached with the binding object's AddSslCertificate
// rather than by writing certificateHash: that method also creates the
// HTTP.sys SSL binding, and a certificateHash written into configuration
// without it produces a site that looks right in IIS Manager and resets
// every TLS connection.
// ---------------------------------------------------------------------------

fn site_filter(params: Value) -> Result[string, string] {
    let site = param_str(params, "site", "")
    if site == "" { return Err("missing 'site' parameter") }
    Ok("system.applicationHost/sites/site[@name='" + xp(site)? + "']/bindings")
}

fn protocol(params: Value) -> Result[string, string] {
    let p = param_str(params, "protocol", "http")
    if p == "http" { return Ok("http") }
    if p == "https" { return Ok("https") }
    if p == "net_tcp" { return Ok("net.tcp") }
    if p == "net_pipe" { return Ok("net.pipe") }
    if p == "net_msmq" { return Ok("net.msmq") }
    if p == "msmq_formatname" { return Ok("msmq.formatname") }
    Err("invalid 'protocol' value '" + p + "'")
}

// address:port:hostheader, IIS's own spelling.
fn binding_information(params: Value) -> string {
    param_str(params, "ip", "*") + ":" + itoa(param_int(params, "port", 80)) + ":" +
        param_str(params, "host_header", "")
}

fn ssl_flags(params: Value) -> Result[int, string] {
    let f = param_str(params, "ssl_flags", "none")
    if f == "none" { return Ok(0) }
    if f == "sni" { return Ok(1) }
    if f == "central_cert_store" { return Ok(2) }
    if f == "sni_central_cert_store" { return Ok(3) }
    Err("invalid 'ssl_flags' value '" + f + "'")
}

// Thumbprints are compared without separators or case: the store hands them
// back as unbroken uppercase hex, but people paste them out of certmgr with
// spaces in.
fn norm_thumb(t: string) -> string {
    t.replace(" ", "").replace(":", "").to_upper()
}

// 'ABSENT', or { ssl_flags, certificate_hash }.
fn probe(params: Value) -> Result[string, string] {
    ps_out(
        "$b = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        ps_q(site_filter(params)? + "/binding") + " | Where-Object {{ " +
        "[string]$_.protocol -eq " + ps_q(protocol(params)?) + " -and " +
        "[string]$_.bindingInformation -eq " + ps_q(binding_information(params)) + " }}); " +
        "if ($b.Count -eq 0) {{ 'ABSENT' }} else {{ " +
        // certificateHash is a byte[] on an https binding and absent or
        // empty on any other, so the hex is only built when it really is one.
        "$h = $b[0].GetAttributeValue('certificateHash'); $hex = ''; " +
        "if ($h -is [byte[]]) {{ $hex = (($h | ForEach-Object {{ $_.ToString('X2') }}) -join '') }} " +
        "elseif ($null -ne $h) {{ $hex = [string]$h }}; " +
        "[pscustomobject]@{{ ssl_flags = [string]$b[0].GetAttributeValue('sslFlags'); " +
        "certificate_hash = $hex }} | ConvertTo-Json -Compress }}")
}

fn wants_certificate(params: Value) -> bool {
    param_str(params, "certificate_thumbprint", "") != "" ||
        param_str(params, "certificate_subject", "") != ""
}

// The thumbprint the step asks for: the one it named, or the newest unexpired
// certificate in the store whose subject matches. Empty when the step named
// none, and empty when it named a subject the store does not hold yet — a
// check runs before any step applies, so the certificate a sibling step is
// about to create is legitimately missing at that point.
fn wanted_thumb(params: Value) -> Result[string, string] {
    let thumb = param_str(params, "certificate_thumbprint", "")
    if thumb != "" { return Ok(norm_thumb(thumb)) }
    let subject = param_str(params, "certificate_subject", "")
    if subject == "" { return Ok("") }
    let store = param_str(params, "certificate_store", "My")
    let found = ps_out(
        "$c = @(Get-ChildItem -Path " + ps_q("Cert:\\LocalMachine\\" + store) +
        " | Where-Object {{ $_.Subject -eq " + ps_q(subject) + " -and $_.NotAfter -gt (Get-Date) }} | " +
        "Sort-Object NotAfter -Descending); " +
        "if ($c.Count -eq 0) {{ '' }} else {{ $c[0].Thumbprint }}")?
    if found == "" { return Ok("") }
    Ok(norm_thumb(found))
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" { return Ok(CheckResult::NotConfigured) }
    let b = json::parse(st)?
    if get_str(b, "ssl_flags") != itoa(ssl_flags(params)?) { return Ok(CheckResult::NotConfigured) }
    let want = wanted_thumb(params)?
    // The certificate the step named is not in the store yet, so the binding
    // cannot be right. apply says why.
    if wants_certificate(params) && want == "" { return Ok(CheckResult::NotConfigured) }
    if want != "" && norm_thumb(get_str(b, "certificate_hash")) != want {
        return Ok(CheckResult::NotConfigured)
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let st = probe(params)?
    let filter = ps_q(site_filter(params)?)
    let proto = protocol(params)?
    let info = binding_information(params)
    let at = "@{{protocol=" + ps_q(proto) + "; bindingInformation=" + ps_q(info) + "}}"
    if !want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing " + proto + " binding " + info)
        ps_run("Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -AtElement " + at)?
        return Ok(ApplyResult::Success)
    }
    let flags = ssl_flags(params)?
    if st == "ABSENT" {
        log::info("adding " + proto + " binding " + info)
        ps_run("Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -Value @{{protocol=" + ps_q(proto) +
            "; bindingInformation=" + ps_q(info) + "; sslFlags=" + itoa(flags) + "}}")?
    } else {
        let b = json::parse(st)?
        if get_str(b, "ssl_flags") != itoa(flags) {
            ps_run("Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                ps_q(site_filter(params)? + "/binding[@protocol='" + xp(proto)? +
                    "'][@bindingInformation='" + xp(info)? + "']") +
                " -Name 'sslFlags' -Value " + itoa(flags))?
        }
    }
    let want = wanted_thumb(params)?
    if want == "" {
        if !wants_certificate(params) { return Ok(ApplyResult::Success) }
        return Err("no unexpired certificate with subject '" +
            param_str(params, "certificate_subject", "") + "' in LocalMachine\\" +
            param_str(params, "certificate_store", "My"))
    }
    let now = probe(params)?
    if now != "ABSENT" && norm_thumb(get_str(json::parse(now)?, "certificate_hash")) == want {
        return Ok(ApplyResult::Success)
    }
    log::info("attaching certificate " + want + " to " + proto + " binding " + info)
    ps_run(
        "$b = Get-WebBinding -Name " + ps_q(param_str(params, "site", "")) +
        " -Protocol " + ps_q(proto) + " -Port " + itoa(param_int(params, "port", 80)) +
        " -HostHeader " + ps_q(param_str(params, "host_header", "")) + "; " +
        "$b.AddSslCertificate(" + ps_q(want) + ", " +
        ps_q(param_str(params, "certificate_store", "My")) + ")")?
    Ok(ApplyResult::Success)
}
