use value
use json
use log
use common

// ---------------------------------------------------------------------------
// A site: the sites collection entry, its root application, and that
// application's root virtual directory — the three elements IIS Manager's
// "Add Web Site" dialog writes in one go.
//
// The site is created with NO bindings, which is what the configuration API
// allows and New-Website does not. That is deliberate: bindings belong to
// windows_iis.binding, and a site that owned its own would fight it. The
// consequence is that a brand new site cannot start until a binding exists,
// so `state` is left :unmanaged on the creating step and set by a later one.
// ---------------------------------------------------------------------------

fn site_filter(params: Value) -> Result[string, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    Ok("system.applicationHost/sites/site[@name='" + common::xp(name)? + "']")
}

fn root_vdir(params: Value) -> Result[string, string] {
    Ok(site_filter(params)? + "/application[@path='/']/virtualDirectory[@path='/']")
}

fn root_app(params: Value) -> Result[string, string] {
    Ok(site_filter(params)? + "/application[@path='/']")
}

// Looked up through ServerManager rather than Get-Website, whose -Name is a
// wildcard pattern: [, ], * and ? in a site name would match other sites, or
// fail to match this one.
fn exists(name: string) -> Result[bool, string] {
    let st = common::ps_out("if ($null -ne (CwSm).Sites[" + common::ps_q(name) +
        "]) {{ 'YES' }} else {{ 'NO' }}")?
    Ok(st == "YES")
}

// { id, physical_path, app_pool, auto_start, state }.
fn probe(params: Value) -> Result[Value, string] {
    let name = common::param_str(params, "name", "")
    json::parse(common::ps_out(
        "$o=@{{}}; " +
        "$o['id']=CwV(Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(site_filter(params)?) + " -Name 'id'); " +
        "$o['physical_path']=CwV(Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(root_vdir(params)?) + " -Name 'physicalPath'); " +
        "$o['app_pool']=CwV(Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(root_app(params)?) + " -Name 'applicationPool'); " +
        "$o['auto_start']=CwV(Get-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
        common::ps_q(site_filter(params)?) + " -Name 'serverAutoStart'); " +
        "$o['state']=''; try {{ $o['state']=[string](CwSm).Sites[" + common::ps_q(name) +
        "].State }} catch {{ }}; " +
        "[pscustomobject]$o | ConvertTo-Json -Compress")?)
}

fn desired_state(params: Value) -> Result[string, string] {
    let s = common::param_str(params, "state", "unmanaged")
    if s == "started" || s == "stopped" || s == "unmanaged" { return Ok(s) }
    Err("invalid 'state' value '" + s + "' (expected :started, :stopped or :unmanaged)")
}

// Windows paths are compared case-insensitively; IIS stores them verbatim, so
// C:\Web and c:\web are the same directory but not the same string.
fn norm_path(p: string) -> string {
    let s = p.replace("/", "\\").to_lower()
    if s.len() > 1 && s.ends_with("\\") { return s.slice(0, s.len() - 1) }
    s
}

fn same_path(a: string, b: string) -> bool { norm_path(a) == norm_path(b) }

fn check(params: Value) -> Result[CheckResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let there = exists(name)?
    if !common::want_present(params)? {
        if there { return Ok(CheckResult::NotConfigured) }
        return Ok(CheckResult::AlreadyConfigured)
    }
    // No physical_path is not an error here even though the site cannot be
    // created without one: a check runs before any step applies, so the step
    // that supplies it may simply not have run yet. apply says so if it is
    // still missing then.
    if !there { return Ok(CheckResult::NotConfigured) }
    let s = probe(params)?
    // Each aspect is only reconciled when the step named it, so a later step
    // can set `state` on a site an earlier one created without restating the
    // path and the pool.
    let path = common::param_str(params, "physical_path", "")
    if path != "" && !same_path(common::get_str(s, "physical_path"), path) { return Ok(CheckResult::NotConfigured) }
    let pool = common::param_str(params, "app_pool", "")
    if pool != "" && common::get_str(s, "app_pool") != pool { return Ok(CheckResult::NotConfigured) }
    if common::has(params, "server_auto_start") {
        let want = if common::param_bool(params, "server_auto_start", true) { "true" } else { "false" }
        if common::get_str(s, "auto_start").to_lower() != want { return Ok(CheckResult::NotConfigured) }
    }
    let id = common::param_int(params, "id", 0)
    if id != 0 && common::get_str(s, "id") != common::itoa(id) { return Ok(CheckResult::NotConfigured) }
    let st = desired_state(params)?
    if st != "unmanaged" && common::get_str(s, "state").to_lower() != st { return Ok(CheckResult::NotConfigured) }
    Ok(CheckResult::AlreadyConfigured)
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = common::param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let qn = common::ps_q(name)
    if !common::want_present(params)? {
        if !exists(name)? { return Ok(ApplyResult::Success) }
        log::info("removing site " + name)
        common::ps_run("$sm = CwSm; $sm.Sites.Remove($sm.Sites[" + qn + "]); $sm.CommitChanges()")?
        return Ok(ApplyResult::Success)
    }
    let path = common::param_str(params, "physical_path", "")
    if !exists(name)? {
        if path == "" {
            return Err("site '" + name + "' does not exist and no 'physical_path' was given to create it")
        }
        let id = common::param_int(params, "id", 0)
        // id = 0 means "let IIS pick", but the configuration API has no
        // auto-numbering the way New-Website does, so pick the next free one.
        let id_expr = if id == 0 {
            "$id = ([int]((Get-Website | ForEach-Object {{ [int]$_.id }} | " +
            "Measure-Object -Maximum).Maximum)) + 1; if ($id -lt 1) {{ $id = 1 }}; "
        } else {
            "$id = " + common::itoa(id) + "; "
        }
        log::info("creating site " + name + " at " + path)
        common::ps_run(
            id_expr +
            "CwMkdir " + common::ps_q(path) + "; " +
            "Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' " +
            "-Filter 'system.applicationHost/sites' -Name '.' -Value @{{name=" + qn + "; id=$id}}; " +
            // Whether adding the application also materialises its root
            // virtual directory depends on virtualDirectoryDefaults, so do
            // not assume either way: add it if it is not there, set it if it
            // is.
            "Add-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(site_filter(params)?) + " -Name '.' -Value @{{path='/'}}; " +
            "$vd = @(Get-WebConfiguration -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(root_app(params)? + "/virtualDirectory") + " | Where-Object {{ [string]$_.GetAttributeValue('path') -eq '/' }}); " +
            "if ($vd.Count -eq 0) {{ Add-WebConfigurationProperty " +
            "-PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " + common::ps_q(root_app(params)?) +
            " -Name '.' -Value @{{path='/'; physicalPath=" + common::ps_q(path) + "}} }} " +
            "else {{ Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(root_vdir(params)?) + " -Name 'physicalPath' -Value " + common::ps_q(path) + " }}"
        )?
    }
    let s = probe(params)?
    let script = ""
    if path != "" && !same_path(common::get_str(s, "physical_path"), path) {
        script = script +
            "CwMkdir " + common::ps_q(path) + "; " +
            "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(root_vdir(params)?) + " -Name 'physicalPath' -Value " + common::ps_q(path) + "; "
    }
    let pool = common::param_str(params, "app_pool", "")
    if pool != "" && common::get_str(s, "app_pool") != pool {
        script = script +
            "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(root_app(params)?) + " -Name 'applicationPool' -Value " + common::ps_q(pool) + "; "
    }
    if common::has(params, "server_auto_start") {
        let on = common::param_bool(params, "server_auto_start", true)
        let want = if on { "true" } else { "false" }
        if common::get_str(s, "auto_start").to_lower() != want {
            script = script +
                "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
                common::ps_q(site_filter(params)?) + " -Name 'serverAutoStart' -Value " +
                (if on { "$true" } else { "$false" }) + "; "
        }
    }
    let id = common::param_int(params, "id", 0)
    if id != 0 && common::get_str(s, "id") != common::itoa(id) {
        script = script +
            "Set-WebConfigurationProperty -PSPath 'MACHINE/WEBROOT/APPHOST' -Filter " +
            common::ps_q(site_filter(params)?) + " -Name 'id' -Value " + common::itoa(id) + "; "
    }
    if script != "" {
        log::info("updating site " + name)
        common::ps_run(script)?
    }
    let st = desired_state(params)?
    if st != "unmanaged" && common::get_str(probe(params)?, "state").to_lower() != st {
        let verb = if st == "started" { "Start" } else { "Stop" }
        common::ps_run("[void](CwSm).Sites[" + qn + "]." + verb + "()")?
    }
    Ok(ApplyResult::Success)
}
