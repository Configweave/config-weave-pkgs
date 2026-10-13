use value
use json
use log
use common

// ---------------------------------------------------------------------------
// An application under a site: the application element plus its root virtual
// directory, which is where physicalPath actually lives.
// ---------------------------------------------------------------------------

fn site_filter(params: Value) -> Result[string, string] {
    let site = common::param_str(params, "site", "")
    if site == "" { return Err("missing 'site' parameter") }
    Ok("system.applicationHost/sites/site[@name='" + common::xp(site)? + "']")
}

// IIS stores an application path with a leading slash and no trailing one.
fn app_path(params: Value) -> Result[string, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    let s = if p.starts_with("/") { p } else { "/" + p }
    if s.len() > 1 && s.ends_with("/") { return Ok(s.slice(0, s.len() - 1)) }
    Ok(s)
}

fn app_filter(params: Value) -> Result[string, string] {
    Ok(site_filter(params)? + "/application[@path='" + common::xp(app_path(params)?)? + "']")
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
    if !common::has(params, name) { return None }
    if kind == "bool" {
        if common::param_bool(params, name, false) { return Some("true") }
        return Some("false")
    }
    let raw = common::param_str(params, name, "")
    if raw == "" { return None }
    Some(raw)
}

fn ps_value(kind: string, want: string) -> string {
    if kind == "bool" {
        if want == "true" { return "$true" }
        return "$false"
    }
    common::ps_q(want)
}

fn exists(params: Value) -> Result[bool, string] {
    let st = common::ps_out("if (@(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(app_filter(params)?) + ").Count -gt 0) {{ 'YES' }} else {{ 'NO' }}")?
    Ok(st == "YES")
}

fn probe(params: Value) -> Result[Value, string] {
    let script = "$o=@{{}}; $o['physical_path']=CwV(Get-WebConfigurationProperty " +
        "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + common::ps_q(vdir_filter(params)?) +
        " -Name 'physicalPath'); "
    for a in attrs() {
        let name = a.get(0).unwrap_or("")
        script = script + "$o[" + common::ps_q(name) + "]=CwV(Get-WebConfigurationProperty " +
            "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + common::ps_q(app_filter(params)?) +
            " -Name " + common::ps_q(a.get(1).unwrap_or("")) + "); "
    }
    json::parse(common::ps_out(script + "[pscustomobject]$o | ConvertTo-Json -Compress")?)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let there = exists(params)?
    if !common::want_present(params)? {
        if there { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // As for a site: a missing physical_path is only an error at apply time,
    // because a check runs before any sibling step has applied.
    if !there { return Ok(CheckResult::NotConfigured) }
    let s = probe(params)?
    let path = common::param_str(params, "physical_path", "")
    if path != "" && !same_path(common::get_str(s, "physical_path"), path) { return Ok(CheckResult::NotConfigured) }
    for a in attrs() {
        let name = a.get(0).unwrap_or("")
        if let Some(want) = desired(params, name, a.get(2).unwrap_or("")) {
            if common::get_str(s, name).to_lower() != want.to_lower() { return Ok(CheckResult::NotConfigured) }
        }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let path = app_path(params)?
    if !common::want_present(params)? {
        if !exists(params)? { return Ok(ApplyResult::Success) }
        log::info("removing application " + path)
        common::ps_run("Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(site_filter(params)?) + " -Name '.' -AtElement @{{path=" + common::ps_q(path) + "}}")?
        return Ok(ApplyResult::Success)
    }
    let physical = common::param_str(params, "physical_path", "")
    if !exists(params)? {
        if physical == "" {
            return Err("application '" + path +
                "' does not exist and no 'physical_path' was given to create it")
        }
        log::info("creating application " + path + " at " + physical)
        common::ps_run(
            "if (-not (Test-Path -LiteralPath " + common::ps_q(physical) + ")) {{ " +
            "New-Item -ItemType Directory -Path " + common::ps_q(physical) + " | Out-Null }}; " +
            // As for a site: whether the application's root virtual
            // directory is materialised with it depends on
            // virtualDirectoryDefaults, so handle both.
            "Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(site_filter(params)?) + " -Name '.' -Value @{{path=" + common::ps_q(path) + "}}; " +
            "$vd = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(app_filter(params)? + "/virtualDirectory") + " | Where-Object {{ [string]$_.GetAttributeValue('path') -eq '/' }}); " +
            "if ($vd.Count -eq 0) {{ Add-WebConfigurationProperty " +
            "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + common::ps_q(app_filter(params)?) +
            " -Name '.' -Value @{{path='/'; physicalPath=" + common::ps_q(physical) + "}} }} " +
            "else {{ Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(vdir_filter(params)?) + " -Name 'physicalPath' -Value " + common::ps_q(physical) + " }}")?
    }
    let s = probe(params)?
    let script = ""
    if physical != "" && !same_path(common::get_str(s, "physical_path"), physical) {
        script = script +
            "if (-not (Test-Path -LiteralPath " + common::ps_q(physical) + ")) {{ " +
            "New-Item -ItemType Directory -Path " + common::ps_q(physical) + " | Out-Null }}; " +
            "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(vdir_filter(params)?) + " -Name 'physicalPath' -Value " + common::ps_q(physical) + "; "
    }
    for a in attrs() {
        let name = a.get(0).unwrap_or("")
        let kind = a.get(2).unwrap_or("")
        if let Some(want) = desired(params, name, kind) {
            if common::get_str(s, name).to_lower() == want.to_lower() { continue }
            script = script +
                "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                common::ps_q(app_filter(params)?) + " -Name " + common::ps_q(a.get(1).unwrap_or("")) +
                " -Value " + ps_value(kind, want) + "; "
        }
    }
    if script != "" {
        log::info("updating application " + path)
        common::ps_run(script)?
    }
    Ok(ApplyResult::Success)
}
