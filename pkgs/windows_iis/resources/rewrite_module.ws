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
// The IIS URL Rewrite module.
//
// URL Rewrite is not part of the IIS role: it is a separate MSI, which is why
// none of the rewrite resources can assume it. Detection is the same for all
// three install methods — the module drops rewrite.dll into inetsrv — so a
// module installed by hand, by Chocolatey or by an image build is recognised
// whichever method this step names.
//
// :msi is the default because it is the only method that works from a service
// or a scheduled task: winget is a per-user package manager, absent on Server
// SKUs and unavailable to SYSTEM, and Chocolatey has to be bootstrapped
// first.
// ---------------------------------------------------------------------------

fn installed() -> Result[bool, string] {
    // Resolved from %windir% rather than assumed to be on C:.
    let out = shell::powershell(
        "$p = Join-Path $env:windir 'system32\\inetsrv\\rewrite.dll'; " +
        "if (Test-Path $p) {{ 'YES' }} else {{ 'NO' }}", Value::Null)?
    if !out.success { return Err(out.stderr.trim()) }
    Ok(out.stdout.trim() == "YES")
}

fn method(params: Value) -> Result[string, string] {
    let m = param_str(params, "method", "msi")
    if m == "msi" || m == "winget" || m == "chocolatey" { return Ok(m) }
    Err("invalid 'method' value '" + m + "' (expected :msi, :winget or :chocolatey)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    method(params)?
    if installed()? == want_present(params)? { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

// msiexec's 3010 and 1641 both mean "done, reboot to finish".
fn run_installer(script: string) -> Result[ApplyResult, string] {
    let out = shell::powershell("$ErrorActionPreference='Stop'; " + script, Value::Null)?
    if out.code == 3010 || out.code == 1641 { return Ok(ApplyResult::RebootRequired) }
    if !out.success {
        let detail = if out.stderr.trim() == "" { out.stdout.trim() } else { out.stderr.trim() }
        return Err(detail)
    }
    Ok(ApplyResult::Success)
}

fn install_msi(params: Value) -> Result[ApplyResult, string] {
    let source = param_str(params, "source", "")
    if source == "" { return Err("'source' is required when method is :msi") }
    let local = if source.starts_with("http://") || source.starts_with("https://") {
        let tmp = fs::temp_file()? + ".msi"
        log::info("downloading " + source)
        http::download(source, tmp, Value::Null)?
        tmp
    } else {
        if !fs::exists(source) { return Err("'source' does not exist: " + source) }
        source
    }
    log::info("installing the URL Rewrite module from " + local)
    run_installer(
        "$p = Start-Process msiexec.exe -ArgumentList @('/i', " + ps_q(local) +
        ", '/qn', '/norestart') -Wait -PassThru; exit $p.ExitCode")
}

fn uninstall_msi() -> Result[ApplyResult, string] {
    log::info("uninstalling the URL Rewrite module")
    // The product is registered under its display name rather than a stable
    // ProductCode across the 2.0 and 2.1 packages, so the code is looked up —
    // and an MSI subkey's own name IS the ProductCode.
    //
    // Both registry views are searched: a 32-bit package registers under
    // WOW6432Node on a 64-bit OS, and searching only the native view meant an
    // x86 install was never found. When nothing matches this now FAILS rather
    // than exiting 0 — the old behaviour reported success while rewrite.dll was
    // still on disk, so the step could never converge and never said why.
    run_installer(
        "$hives = @('HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall', " +
        "'HKLM:\\SOFTWARE\\WOW6432Node\\Microsoft\\Windows\\CurrentVersion\\Uninstall'); " +
        "$k = $hives | Where-Object {{ Test-Path $_ }} | " +
        "ForEach-Object {{ Get-ChildItem $_ -ErrorAction SilentlyContinue }} | " +
        "ForEach-Object {{ Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue }} | " +
        "Where-Object {{ $_.DisplayName -like 'IIS URL Rewrite Module*' }} | " +
        "Sort-Object DisplayVersion -Descending | Select-Object -First 1; " +
        "if ($null -eq $k) {{ " +
        "Write-Error 'the URL Rewrite module is installed but has no uninstall entry in either " +
        "registry view; remove it by hand or with its own installer'; exit 1 }}; " +
        "$p = Start-Process msiexec.exe -ArgumentList @('/x', $k.PSChildName, '/qn', '/norestart') " +
        "-Wait -PassThru; exit $p.ExitCode")
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let how = method(params)?
    if !want_present(params)? {
        if !installed()? { return Ok(ApplyResult::Success) }
        if how == "winget" {
            return run_installer("winget uninstall -e --id Microsoft.IIS.URLRewrite " +
                "--silent --accept-source-agreements")
        }
        if how == "chocolatey" { return run_installer("choco uninstall urlrewrite -y") }
        return uninstall_msi()
    }
    if installed()? { return Ok(ApplyResult::Success) }
    if how == "winget" {
        log::info("installing the URL Rewrite module with winget")
        return run_installer("winget install -e --id Microsoft.IIS.URLRewrite " +
            "--silent --accept-package-agreements --accept-source-agreements")
    }
    if how == "chocolatey" {
        log::info("installing the URL Rewrite module with Chocolatey")
        return run_installer("choco install urlrewrite -y --no-progress")
    }
    install_msi(params)
}
