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

// 'ABSENT', or the attributes this resource owns. The virtual directory is
// matched as IIS matches it, case-insensitively, and "path" is its path as
// IIS stores it, so the XPath that addresses it for an update matches too.
// The password reads back decrypted, which is what lets a changed password be
// detected rather than written only alongside a changed userName.
fn probe(params: Value) -> Result[string, string] {
    common::ps_out(
        "$v = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(app_filter(params)? + "/virtualDirectory") + " | Where-Object {{ " +
        "[string]$_.path -eq " + common::ps_q(vdir_path(params)?) + " }}); " +
        "if ($v.Count -eq 0) {{ 'ABSENT' }} else {{ [pscustomobject]@{{ " +
        "path = CwV($v[0].GetAttributeValue('path')); " +
        "physical_path = CwV($v[0].GetAttributeValue('physicalPath')); " +
        "username = CwV($v[0].GetAttributeValue('userName')); " +
        "password = CwV($v[0].GetAttributeValue('password')); " +
        "logon_method = (CwEnum $v[0] 'logonMethod' (CwV($v[0].GetAttributeValue('logonMethod')))); " +
        "allow_sub_dir_config = CwV($v[0].GetAttributeValue('allowSubDirConfig')) }} | " +
        "ConvertTo-Json -Compress }}")
}

// [IIS attribute, desired text, kind] for every attribute that differs.
fn drift(params: Value, v: Value) -> Result[List[List[string]], string] {
    let out: List[List[string]] = []
    let physical = common::param_str(params, "physical_path", "")
    if physical != "" && norm_path(common::get_str(v, "physical_path")) != norm_path(physical) {
        out.push(["physicalPath", physical, "str"])
    }
    let user = common::param_str(params, "username", "")
    let pw = common::param_str(params, "password", "")
    if common::param_bool(params, "pass_through", false) {
        if user != "" || pw != "" {
            return Err("pass_through = true cannot be combined with 'username' or 'password'")
        }
        if common::get_str(v, "username") != "" { out.push(["userName", "", "str"]) }
        if common::get_str(v, "password") != "" { out.push(["password", "", "secret"]) }
    } else if user != "" {
        if common::get_str(v, "username") != user { out.push(["userName", user, "str"]) }
        if common::get_str(v, "password") != pw { out.push(["password", pw, "secret"]) }
    }
    let lm = logon_method(params)?
    if lm != "" && common::get_str(v, "logon_method").to_lower() != lm.to_lower() {
        out.push(["logonMethod", lm, "str"])
    }
    if common::has(params, "allow_sub_dir_config") {
        let want = if common::param_bool(params, "allow_sub_dir_config", true) { "true" } else { "false" }
        if common::get_str(v, "allow_sub_dir_config").to_lower() != want {
            out.push(["allowSubDirConfig", want, "bool"])
        }
    }
    Ok(out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let st = probe(params)?
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    if st == "ABSENT" {
        if common::param_str(params, "physical_path", "") == "" {
            return Err("virtual directory '" + vdir_path(params)? +
                "' does not exist and no 'physical_path' was given to create it")
        }
        return Ok(CheckResult::NotConfigured)
    }
    if drift(params, json::parse(st)?)?.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    Ok(CheckResult::NotConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let path = vdir_path(params)?
    let st = probe(params)?
    let filter = common::ps_q(app_filter(params)?)
    if !common::want_present(params)? {
        if st == "ABSENT" { return Ok(ApplyResult::Success) }
        log::info("removing virtual directory " + path)
        common::ps_run("Remove-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -AtElement @{{path=" +
            common::ps_q(common::get_str(json::parse(st)?, "path")) + "}}")?
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
            "if (-not " + common::ps_q(physical) + ".StartsWith('\\\\')) {{ CwMkdir " + common::ps_q(physical) + " }}; " +
            "Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            filter + " -Name '.' -Value @{{path=" + common::ps_q(path) + "; physicalPath=" +
            common::ps_q(physical) + "}}")?
    }
    let v = json::parse(probe(params)?)?
    let elem = common::ps_q(app_filter(params)? + "/virtualDirectory[@path='" +
        common::xp(common::get_str(v, "path"))? + "']")
    let script = ""
    for d in drift(params, v)? {
        let attr = d.get(0).unwrap_or("")
        let kind = d.get(2).unwrap_or("")
        let lit = if kind == "secret" { "$env:CW_SECRET" }
            else if kind == "bool" { if d.get(1).unwrap_or("") == "true" { "$true" } else { "$false" } }
            else { common::ps_q(d.get(1).unwrap_or("")) }
        script = script + "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            elem + " -Name " + common::ps_q(attr) + " -Value " + lit + "; "
    }
    if script != "" {
        log::info("updating virtual directory " + path)
        // The password goes through the environment, never the script text.
        common::ps_run_env(script, common::secret_env(common::param_str(params, "password", "")))?
    }
    Ok(ApplyResult::Success)
}
