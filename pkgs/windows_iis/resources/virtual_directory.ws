use value
use json
use log
use common

// ---------------------------------------------------------------------------
// A virtual directory under an application. The application's own root
// virtual directory (path "/") belongs to windows_iis.application; this is
// for the extra ones.
//
// A UNC physical_path is not created — only a local one is — because the
// credentials that would create it are the ones IIS uses to read it, and
// creating a share directory is windows_share's job.
// ---------------------------------------------------------------------------

fn app_filter(params: Value) -> Result[string, string] {
    let site = common::param_str(params, "site", "")
    if site == "" { return Err("missing 'site' parameter") }
    let app = common::param_str(params, "application", "/")
    Ok("system.applicationHost/sites/site[@name='" + common::xp(site)? + "']/application[@path='" +
        common::xp(app)? + "']")
}

fn vdir_path(params: Value) -> Result[string, string] {
    let p = common::param_str(params, "path", "")
    if p == "" { return Err("missing 'path' parameter") }
    let s = if p.starts_with("/") { p } else { "/" + p }
    if s.len() > 1 && s.ends_with("/") { return Ok(s.slice(0, s.len() - 1)) }
    Ok(s)
}

fn norm_path(p: string) -> string {
    let s = p.replace("/", "\\").to_lower()
    if s.len() > 1 && s.ends_with("\\") { return s.slice(0, s.len() - 1) }
    s
}

fn logon_method(params: Value) -> Result[string, string] {
    let m = common::param_str(params, "logon_method", "")
    if m == "" { return Ok("") }
    if m == "interactive" { return Ok("Interactive") }
    if m == "batch" { return Ok("Batch") }
    if m == "network" { return Ok("Network") }
    if m == "cleartext" { return Ok("ClearText") }
    Err("invalid 'logon_method' value '" + m + "'")
}

// 'ABSENT', or the attributes this resource owns.
fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$v = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(app_filter(params)? + "/virtualDirectory") + " | Where-Object {{ " +
        "[string]$_.path -eq " + common::ps_q(vdir_path(params)?) + " }}); " +
        "if ($v.Count -eq 0) {{ 'ABSENT' }} else {{ [pscustomobject]@{{ " +
        "physical_path = CwV($v[0].GetAttributeValue('physicalPath')); " +
        "username = CwV($v[0].GetAttributeValue('userName')); " +
        "logon_method = CwV($v[0].GetAttributeValue('logonMethod')); " +
        "allow_sub_dir_config = CwV($v[0].GetAttributeValue('allowSubDirConfig')) }} | " +
        "ConvertTo-Json -Compress }}")
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let path = common::param_str(params, "physical_path", "")
    if st == "ABSENT" {
        if path == "" {
            return Err("virtual directory '" + vdir_path(params)? +
                "' does not exist and no 'physical_path' was given to create it")
        }
        return Ok(CheckResult::NotConfigured)
    }
    let v = json::parse(st)?
    if path != "" && norm_path(common::get_str(v, "physical_path")) != norm_path(path) {
        return Ok(CheckResult::NotConfigured)
    }
    let user = common::param_str(params, "username", "")
    if user != "" && common::get_str(v, "username") != user { return Ok(CheckResult::NotConfigured) }
    let lm = logon_method(params)?
    if lm != "" && common::get_str(v, "logon_method").to_lower() != lm.to_lower() {
        return Ok(CheckResult::NotConfigured)
    }
    if common::has(params, "allow_sub_dir_config") {
        let want = if common::param_bool(params, "allow_sub_dir_config", true) { "true" } else { "false" }
        if common::get_str(v, "allow_sub_dir_config").to_lower() != want { return Ok(CheckResult::NotConfigured) }
    }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let path = vdir_path(params)?
    let st = probe(params)?
    let filter = common::ps_q(app_filter(params)?)
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing virtual directory " + path)
        common::ps_run("Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -AtElement @{{path=" + common::ps_q(path) + "}}")?
        return Ok(ApplyResult::Success)
    }
    let physical = common::param_str(params, "physical_path", "")
    if st == "ABSENT" {
        if physical == "" {
            return Err("virtual directory '" + path +
                "' does not exist and no 'physical_path' was given to create it")
        }
        log::info("creating virtual directory " + path + " at " + physical)
        // A UNC path is left alone; anything else is created if missing.
        common::ps_run(
            "if (-not " + common::ps_q(physical) + ".StartsWith('\\\\') -and " +
            "-not (Test-Path -LiteralPath " + common::ps_q(physical) + ")) {{ " +
            "New-Item -ItemType Directory -Path " + common::ps_q(physical) + " | Out-Null }}; " +
            "Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -Value @{{path=" + common::ps_q(path) + "; physicalPath=" +
            common::ps_q(physical) + "}}")?
    }
    let elem = common::ps_q(app_filter(params)? + "/virtualDirectory[@path='" + common::xp(path)? + "']")
    let script = ""
    let v = json::parse(probe(params)?)?
    if physical != "" && norm_path(common::get_str(v, "physical_path")) != norm_path(physical) {
        script = script + "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            elem + " -Name 'physicalPath' -Value " + common::ps_q(physical) + "; "
    }
    let user = common::param_str(params, "username", "")
    if user != "" && common::get_str(v, "username") != user {
        script = script + "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            elem + " -Name 'userName' -Value " + common::ps_q(user) + "; " +
            "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            elem + " -Name 'password' -Value " + common::ps_q(common::param_str(params, "password", "")) + "; "
    }
    let lm = logon_method(params)?
    if lm != "" && common::get_str(v, "logon_method").to_lower() != lm.to_lower() {
        script = script + "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            elem + " -Name 'logonMethod' -Value " + common::ps_q(lm) + "; "
    }
    if common::has(params, "allow_sub_dir_config") {
        let on = common::param_bool(params, "allow_sub_dir_config", true)
        let want = if on { "true" } else { "false" }
        if common::get_str(v, "allow_sub_dir_config").to_lower() != want {
            script = script + "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                elem + " -Name 'allowSubDirConfig' -Value " +
                (if on { "$true" } else { "$false" }) + "; "
        }
    }
    if script != "" {
        log::info("updating virtual directory " + path)
        common::ps_run(script)?
    }
    Ok(ApplyResult::Success)
}
