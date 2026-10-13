use value
use shell
use json

// ---------------------------------------------------------------------------
// Shared IIS helpers for every script in this package.
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

// A PowerShell single-quoted literal. PowerShell treats the curly quotes
// U+2018 to U+201B as apostrophes too, so each is doubled like ' is.
fn ps_q(s: string) -> string {
    let out = s.replace("'", "''")
    for c in ["‘", "’", "‚", "‛"] { out = out.replace(c, c + c) }
    "'" + out + "'"
}

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
// CwEnum reads an enum or flags attribute off an element whose
// GetAttributeValue hands back the ordinal (GetCollection() items, either
// the provider's or Microsoft.Web.Administration's) and maps it to the schema
// name — flags as the comma-joined names of the set bits, "" for none. Any
// other attribute returns $fallback. CwKind says which: enum, flags or "".
//
// CwSm hands back a Microsoft.Web.Administration ServerManager, whose Sites
// and ApplicationPools indexers look a name up exactly. The WebAdministration
// cmdlets' -Name (Get-Website, Start-WebAppPool, ...) is a wildcard pattern,
// so a site called "a[1]" would not be found by its own name. CwMkdir
// creates a directory without New-Item's wildcard-aware -Path.
//
// CwEp names the HTTP.sys endpoint an https binding element's certificate
// lives on — "sni:<host>:<port>" with SNI, "ip:<address>:<port>" without, ""
// with the central certificate store, which keeps none — and CwHttps lists
// every https binding element on every site, so a removal can tell whether
// another binding still uses an endpoint. CwDelSsl deletes the HTTP.sys
// certificate binding for such an endpoint with netsh, quietly when there is
// none.
fn ps_head() -> string {
    "$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; " +
    "Import-Module WebAdministration; " +
    "function CwV($x) {{ " +
    "if ($null -eq $x) {{ return '' }}; " +
    "if ($x.PSObject.Properties.Name -contains 'Value') {{ $x = $x.Value }}; " +
    "if ($null -eq $x) {{ return '' }}; " +
    "if ($x -is [bool]) {{ if ($x) {{ return 'true' }} else {{ return 'false' }} }}; " +
    "if ($x -is [timespan]) {{ return $x.ToString() }}; " +
    "return ([string]$x) }}; " +
    "function CwSm {{ Add-Type -Path (Join-Path $env:windir 'system32\\inetsrv\\Microsoft.Web.Administration.dll'); " +
    "New-Object Microsoft.Web.Administration.ServerManager }}; " +
    "function CwMkdir($p) {{ [void][IO.Directory]::CreateDirectory($p) }}; " +
    "function CwEp($x) {{ $f = [int]$x.GetAttributeValue('sslFlags'); $p = ([string]$x.bindingInformation).Split(':'); " +
    "$i = $p[0]; if ($i -eq '*' -or $i -eq '') {{ $i = '0.0.0.0' }}; " +
    "if (($f -band 2) -ne 0) {{ return '' }}; " +
    "if (($f -band 1) -ne 0) {{ return ('sni:' + ($p[2..($p.Count - 1)] -join ':') + ':' + $p[1]).ToLower() }}; " +
    "return ('ip:' + $i + ':' + $p[1]) }}; " +
    "function CwDelSsl($ep) {{ if ($ep.StartsWith('ip:')) {{ $a = 'ipport=' + $ep.Substring(3) }} " +
    "elseif ($ep.StartsWith('sni:')) {{ $a = 'hostnameport=' + $ep.Substring(4) }} else {{ return }}; " +
    "$o = & netsh http delete sslcert $a 2>&1; if ($LASTEXITCODE -ne 0 -and -not (($o -join ' ') -match 'cannot find')) {{ throw ('netsh http delete sslcert ' + $a + ': ' + ($o -join ' ')) }} }}; " +
    "function CwHttps {{ @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter 'system.applicationHost/sites/site/bindings/binding' | " +
    "Where-Object {{ [string]$_.protocol -eq 'https' }}) }}; " +
    "function CwKind($el, $name) {{ try {{ $sch = $el.Schema.AttributeSchemas[$name]; " +
    "if ([string]$sch.Type -eq 'flags' -or $sch.IsCombinedFlags -eq $true) {{ return 'flags' }}; " +
    "if ([string]$sch.Type -eq 'enum' -or ($null -ne $sch.EnumValues -and @($sch.EnumValues).Count -gt 0)) {{ return 'enum' }} }} catch {{ }}; return '' }}; " +
    "function CwEnum($el, $name, $fallback) {{ try {{ " +
    "$k = CwKind $el $name; if ($k -eq '') {{ return $fallback }}; " +
    "$sch = $el.Schema.AttributeSchemas[$name]; " +
    "$evs = @(); try {{ $evs = @($sch.GetEnumValues()) }} catch {{ if ($null -ne $sch.EnumValues) {{ $evs = @($sch.EnumValues) }} }}; " +
    "$v = [int64]$el.GetAttributeValue($name); " +
    "if ($k -eq 'flags') {{ $n = @(); foreach ($ev in $evs) {{ " +
    "$b = [int64]$ev.Value; if ($b -ne 0 -and (($b -band ($b - 1)) -eq 0) -and (($v -band $b) -eq $b)) {{ $n += [string]$ev.Name }} }}; " +
    "return ($n -join ',') }}; " +
    "foreach ($ev in $evs) {{ if ([int64]$ev.Value -eq $v) {{ return [string]$ev.Name }} }} " +
    "}} catch {{ }}; return $fallback }}; "
}

// Flags compared as sets: IIS reports them in its own order and spacing, and
// an empty set reads back as "None" (or "") however it was written.
fn flag_set(text: string) -> List[string] {
    let out: List[string] = []
    for p in text.split(",") {
        let t = p.trim().to_lower()
        if t == "" || t == "none" || out.contains(t) { continue }
        out.push(t)
    }
    out
}

fn same_flags(have: string, want: string) -> bool {
    let h = flag_set(have)
    let w = flag_set(want)
    if h.len() != w.len() { return false }
    for x in w { if !h.contains(x) { return false } }
    true
}

// The error for a failed command: stderr, else stdout (where sc.exe, msiexec
// and friends report), with the exit code.
fn failure(out: CmdOutput) -> string {
    let text = out.stderr.trim()
    if text == "" { text = out.stdout.trim() }
    if text == "" { text = "no output" }
    "exit code " + itoa(out.code) + ": " + text
}

fn ps_out(script: string) -> Result[string, string] {
    ps_out_env(script, Value::Map(#{}))
}

fn ps_run(script: string) -> Result[unit, string] {
    ps_out_env(script, Value::Map(#{}))?
    Ok(())
}

// Secrets never go into the script text, which is the -Command argument and
// so visible in the process list and echoed in PowerShell's own error
// messages. They travel in the environment instead: pass
// #{ "CW_SECRET": Value::String(pw) } and read $env:CW_SECRET in the script.
fn ps_out_env(script: string, env: Value) -> Result[string, string] {
    let out = shell::powershell(ps_head() + script, Value::Map(#{ "env": env }))?
    if !out.success { return Err(failure(out)) }
    Ok(out.stdout.trim())
}

fn ps_run_env(script: string, env: Value) -> Result[unit, string] {
    ps_out_env(script, env)?
    Ok(())
}

// Set-WebConfigurationProperty with a filter that is already PowerShell
// quoted. It treats a value differing from the stored one only in case as
// unchanged and writes nothing, so a case-only change goes through a
// temporary value first; otherwise a resource comparing case-sensitively
// would report the same drift after every apply.
fn set_prop(scope: string, qfilter: string, attr: string, lit: string, have: string, want: string) -> string {
    let set = "Set-WebConfigurationProperty" + scope + " -Filter " + qfilter + " -Name " + ps_q(attr) + " -Value "
    if have != want && have.to_lower() == want.to_lower() {
        return set + "(" + lit + " + '#cw'); " + set + lit + "; "
    }
    set + lit + "; "
}

fn secret_env(value: string) -> Value {
    Value::Map(#{ "CW_SECRET": Value::String(value) })
}

// An IIS attribute or element name spliced into PowerShell or an XPath
// expression unquoted: $s.<name>, @{<name>=...}, [@<name>='...']. Schema names
// are letters, digits, '_' and '.' (for a child element's attribute), so
// anything else is refused rather than escaped.
fn attr_name(what: string, name: string) -> Result[string, string] {
    if name == "" { return Err("'" + what + "' is empty") }
    let ok = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_."
    for c in name.chars() {
        if !ok.contains(str(c)) {
            return Err("'" + what + "' value '" + name + "' is not an IIS attribute name (letters, digits, '_' and '.' only)")
        }
    }
    Ok(name)
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
