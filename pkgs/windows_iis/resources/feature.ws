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
// IIS role services.
//
// This is the one resource here that does not touch WebAdministration: it is
// what installs the module the rest of the package needs, so the shared
// ps_out/ps_run above — which import WebAdministration — cannot be used. The
// ServerManager cmdlets below stand in for them.
//
// The symbol names are the Web-* feature names made WCL-spellable: a WCL
// symbol stops at [A-Za-z0-9_], so Web-Asp-Net45 is :asp_net45 and the table
// puts the hyphens back. config-weave has already checked the value against
// the declared set, so all that is left here is spelling.
// ---------------------------------------------------------------------------

fn feature_names() -> List[List[string]] { [
        ["web_server", "Web-Server"],
        ["web_webserver", "Web-WebServer"],
        ["common_http", "Web-Common-Http"],
        ["default_doc", "Web-Default-Doc"],
        ["dir_browsing", "Web-Dir-Browsing"],
        ["http_errors", "Web-Http-Errors"],
        ["static_content", "Web-Static-Content"],
        ["http_redirect", "Web-Http-Redirect"],
        ["dav_publishing", "Web-DAV-Publishing"],
        ["health", "Web-Health"],
        ["http_logging", "Web-Http-Logging"],
        ["custom_logging", "Web-Custom-Logging"],
        ["log_libraries", "Web-Log-Libraries"],
        ["odbc_logging", "Web-ODBC-Logging"],
        ["request_monitor", "Web-Request-Monitor"],
        ["http_tracing", "Web-Http-Tracing"],
        ["performance", "Web-Performance"],
        ["stat_compression", "Web-Stat-Compression"],
        ["dyn_compression", "Web-Dyn-Compression"],
        ["security", "Web-Security"],
        ["filtering", "Web-Filtering"],
        ["basic_auth", "Web-Basic-Auth"],
        ["cert_provider", "Web-CertProvider"],
        ["client_auth", "Web-Client-Auth"],
        ["digest_auth", "Web-Digest-Auth"],
        ["cert_auth", "Web-Cert-Auth"],
        ["ip_security", "Web-IP-Security"],
        ["url_auth", "Web-Url-Auth"],
        ["windows_auth", "Web-Windows-Auth"],
        ["app_dev", "Web-App-Dev"],
        ["net_ext", "Web-Net-Ext"],
        ["net_ext45", "Web-Net-Ext45"],
        ["app_init", "Web-AppInit"],
        ["asp", "Web-ASP"],
        ["asp_net", "Web-Asp-Net"],
        ["asp_net45", "Web-Asp-Net45"],
        ["cgi", "Web-CGI"],
        ["isapi_ext", "Web-ISAPI-Ext"],
        ["isapi_filter", "Web-ISAPI-Filter"],
        ["includes", "Web-Includes"],
        ["websockets", "Web-WebSockets"],
        ["ftp_server", "Web-Ftp-Server"],
        ["ftp_service", "Web-Ftp-Service"],
        ["ftp_ext", "Web-Ftp-Ext"],
        ["mgmt_tools", "Web-Mgmt-Tools"],
        ["mgmt_console", "Web-Mgmt-Console"],
        ["scripting_tools", "Web-Scripting-Tools"],
        ["mgmt_service", "Web-Mgmt-Service"],
        ["mgmt_compat", "Web-Mgmt-Compat"],
        ["metabase", "Web-Metabase"],
        ["lgcy_mgmt_console", "Web-Lgcy-Mgmt-Console"],
        ["lgcy_scripting", "Web-Lgcy-Scripting"],
        ["wmi", "Web-WMI"],
    ] }

fn feature_name(params: Value) -> Result[string, string] {
    let sym = param_str(params, "name", "")
    if sym == "" { return Err("missing 'name' parameter") }
    for row in feature_names() {
        if row.get(0).unwrap_or("") == sym { return Ok(row.get(1).unwrap_or("")) }
    }
    Err("unknown role service ':" + sym + "'")
}

// Get-WindowsFeature is Server-only; it errors on a client SKU, and this
// package targets Windows Server.
fn installed(name: string) -> Result[bool, string] {
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; if ((Get-WindowsFeature -Name " + ps_q(name) +
        ").Installed) {{ 'YES' }} else {{ 'NO' }}", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "YES")
}

fn check(params: Value) -> Result[CheckResult, string] {
    if installed(feature_name(params)?)? == want_present(params)? {
        return Ok(CheckResult::AlreadyConfigured)
    }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = feature_name(params)?
    let cmdlet = if want_present(params)? {
        let mgmt = if param_bool(params, "include_management_tools", false) {
            " -IncludeManagementTools"
        } else { "" }
        "Install-WindowsFeature -Name " + ps_q(name) + mgmt
    } else {
        "Uninstall-WindowsFeature -Name " + ps_q(name)
    }
    log::info("role service " + name)
    // 3010 is the MSI convention for "done, but reboot"; using it as the exit
    // code keeps the reboot signal out of stdout parsing.
    let out = shell::powershell(
        "$ErrorActionPreference='Stop'; $r = " + cmdlet +
        "; if ($r.RestartNeeded -ne 'No') {{ exit 3010 }} else {{ exit 0 }}", Value::Null)?
    if out.code == 3010 { return Ok(ApplyResult::RebootRequired) }
    if !out.success { return Err(out.stderr.trim()) }
    Ok(ApplyResult::Success)
}
