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
// The application pool itself: its existence, its runtime state, and the
// attributes on the pool element and its processModel child. The recycling,
// failure and cpu children are their own resources, so a playbook that only
// wants a nightly recycle does not have to restate the pool's identity.
//
// The attribute half below is the same read-diff-write the section resources
// in this package use; it is repeated rather than shared because wscript has
// no script-to-script imports yet.
// ---------------------------------------------------------------------------

fn section(params: Value) -> Result[string, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    Ok("system.applicationHost/applicationPools/add[@name='" + xp(name)? + "']")
}

// [param, IIS attribute, kind]
fn attrs() -> List[List[string]] { [
        ["auto_start", "autoStart", "bool"],
        ["managed_runtime_version", "managedRuntimeVersion", "sym"],
        ["managed_pipeline_mode", "managedPipelineMode", "sym"],
        ["enable_32bit", "enable32BitAppOnWin64", "bool"],
        ["start_mode", "startMode", "sym"],
        ["queue_length", "queueLength", "int"],
        ["enable_configuration_override", "enableConfigurationOverride", "bool"],
        ["identity_type", "processModel.identityType", "sym"],
        ["username", "processModel.userName", "str"],
        ["password", "processModel.password", "str"],
        ["idle_timeout", "processModel.idleTimeout", "dur"],
        ["idle_timeout_action", "processModel.idleTimeoutAction", "sym"],
        ["max_processes", "processModel.maxProcesses", "int"],
        ["load_user_profile", "processModel.loadUserProfile", "bool"],
        ["set_profile_environment", "processModel.setProfileEnvironment", "bool"],
        ["ping_enabled", "processModel.pingingEnabled", "bool"],
        ["ping_interval", "processModel.pingInterval", "dur"],
        ["ping_response_time", "processModel.pingResponseTime", "dur"],
        ["startup_time_limit", "processModel.startupTimeLimit", "dur"],
        ["shutdown_time_limit", "processModel.shutdownTimeLimit", "dur"],
        ["logon_type", "processModel.logonType", "sym"],
        ["manual_group_membership", "processModel.manualGroupMembership", "bool"],
    ] }

// :none is the empty string IIS stores for "No Managed Code" — the one symbol
// here whose token is not a word.
fn sym_map() -> List[List[string]] { [
        ["managed_runtime_version", "none", ""],
        ["managed_runtime_version", "v1_1", "v1.1"],
        ["managed_runtime_version", "v2_0", "v2.0"],
        ["managed_runtime_version", "v4_0", "v4.0"],
        ["managed_pipeline_mode", "integrated", "Integrated"],
        ["managed_pipeline_mode", "classic", "Classic"],
        ["start_mode", "on_demand", "OnDemand"],
        ["start_mode", "always_running", "AlwaysRunning"],
        ["identity_type", "application_pool_identity", "ApplicationPoolIdentity"],
        ["identity_type", "local_service", "LocalService"],
        ["identity_type", "local_system", "LocalSystem"],
        ["identity_type", "network_service", "NetworkService"],
        ["identity_type", "specific_user", "SpecificUser"],
        ["idle_timeout_action", "terminate", "Terminate"],
        ["idle_timeout_action", "suspend", "Suspend"],
        ["logon_type", "batch", "LogonBatch"],
        ["logon_type", "service", "LogonService"],
    ] }

fn iis_symbol(name: string, v: string) -> string {
    for row in sym_map() {
        if row.get(0).unwrap_or("") == name && row.get(1).unwrap_or("") == v {
            return row.get(2).unwrap_or("")
        }
    }
    v
}

fn desired(params: Value, name: string, kind: string) -> Option[string] {
    if !has(params, name) { return None }
    if kind == "bool" {
        if param_bool(params, name, false) { return Some("true") }
        return Some("false")
    }
    if kind == "int" { return Some(itoa(param_int(params, name, 0))) }
    if kind == "dur" { return Some(hms(param_int(params, name, 0))) }
    let raw = param_str(params, name, "")
    if raw == "" { return None }
    if kind == "sym" { return Some(iis_symbol(name, raw)) }
    Some(raw)
}

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

fn same(kind: string, have: string, want: string) -> bool {
    if kind == "bool" || kind == "sym" {
        return have.replace(" ", "").to_lower() == want.replace(" ", "").to_lower()
    }
    have == want
}

fn ps_value(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    if kind == "int" { return want }
    ps_q(want)
}

// Read through the pool element rather than Get-WebConfigurationProperty:
// identityType, managedPipelineMode, startMode, idleTimeoutAction and
// logonType are all enums, and the property cmdlet hands back their raw
// numbers while the provider renders the schema name as a property.
fn probe_attrs(params: Value, rows: List[List[string]]) -> Result[Value, string] {
    let filter = ps_q(section(params)?)
    let reads = ""
    for r in rows {
        let name = ps_q(r.get(0).unwrap_or(""))
        reads = reads + "$o[" + name + "]=''; try {{ $o[" + name + "]=CwV($s." +
            r.get(1).unwrap_or("") + ") }} catch {{ }}; "
    }
    json::parse(ps_out(
        "$o=@{{}}; $s=$null; try {{ $s = Get-WebConfiguration " +
        "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + filter + " }} catch {{ }}; " +
        "if ($null -ne $s) {{ " + reads + "}}; " +
        "[pscustomobject]$o | ConvertTo-Json -Compress")?)
}

fn exists(name: string) -> Result[bool, string] {
    let st = ps_out("if (Test-Path (Join-Path 'IIS:\\AppPools' " + ps_q(name) +
        ")) {{ 'YES' }} else {{ 'NO' }}")?
    Ok(st == "YES")
}

// Started | Stopped | Starting | Stopping | Unknown.
fn pool_state(name: string) -> Result[string, string] {
    ps_out("(Get-WebAppPoolState -Name " + ps_q(name) + ").Value")
}

fn desired_state(params: Value) -> Result[string, string] {
    let s = param_str(params, "state", "unmanaged")
    if s == "started" || s == "stopped" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'state' value '" + s + "' (expected :started, :stopped or :unmanaged)")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let there = exists(name)?
    if !want_present(params)? {
        if there { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    if !there { return Ok(CheckResult::NotConfigured) }
    let rows = wanted(params)
    if !rows.is_empty() {
        let have = probe_attrs(params, rows)?
        for r in rows {
            if !same(r.get(2).unwrap_or(""), get_str(have, r.get(0).unwrap_or("")),
                     r.get(3).unwrap_or("")) {
                return Ok(CheckResult::NotConfigured)
            }
        }
    }
    let st = desired_state(params)?
    // A pool mid-transition counts as not yet configured; apply nudges it.
    if st != "unmanaged" && pool_state(name)?.to_lower() != st { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = ps_q(name)
    if !want_present(params)? {
        if !exists(name)? { return Ok(ApplyResult::Success) }
        log::info("removing application pool " + name)
        ps_run("Remove-WebAppPool -Name " + qn)?
        return Ok(ApplyResult::Success)
    }
    if !exists(name)? {
        log::info("creating application pool " + name)
        ps_run("New-WebAppPool -Name " + qn + " | Out-Null")?
    }
    let rows = wanted(params)
    if !rows.is_empty() {
        let have = probe_attrs(params, rows)?
        let filter = ps_q(section(params)?)
        let script = ""
        for r in rows {
            let attr = r.get(1).unwrap_or("")
            let kind = r.get(2).unwrap_or("")
            let want = r.get(3).unwrap_or("")
            if same(kind, get_str(have, r.get(0).unwrap_or("")), want) { continue }
            log::info("setting " + name + " " + attr)
            script = script +
                "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                filter + " -Name " + ps_q(attr) + " -Value " + ps_value(kind, want) + "; "
        }
        if script != "" { ps_run(script)? }
    }
    let st = desired_state(params)?
    if st != "unmanaged" && pool_state(name)?.to_lower() != st {
        if st == "started" {
            ps_run("Start-WebAppPool -Name " + qn)?
        } else {
            ps_run("Stop-WebAppPool -Name " + qn)?
        }
    }
    Ok(ApplyResult::Success)
}
