use value
use sys
use log
use registry
use http
use time
use service
use common
use ssrs

// What Report Server Configuration Manager does, through the report server's
// WMI provider (lib/ssrs.ws): the service identity, the catalogue database
// and the service account's rights on it, the database connection, the web
// service and web portal virtual directories and URL reservations, the
// enabled features, and initialisation.

struct Want {
    inst: string,
    db_server: string,
    db_name: string,
    cred: string,
    logon_type: int,
    db_user: string,
    db_password: string,
    ws_url: string,
    ws_vdir: string,
    portal_url: string,
    portal_vdir: string,
    account: string,
    password: string,
}

// The revisions of the two passwords the provider cannot read back are kept here.
fn marker_key(inst: string) -> string {
    "HKLM\\SOFTWARE\\config-weave\\mssql\\reporting_services_config\\" + inst
}

fn check_url(key: string, u: string) -> Result[unit, string] {
    if u.starts_with("https://") {
        return Err("'" + key + "' is an HTTPS URL; HTTPS needs a certificate binding, which this resource does not manage yet; reserve it with Report Server Configuration Manager")
    }
    if !u.starts_with("http://") { return Err("invalid '" + key + "' '" + u + "' (expected http://<host>:<port>, e.g. http://+:80)") }
    let rest = u.slice(7, u.len())
    if rest == "" || rest.contains("/") || !common::only_chars(rest, "+*.:-_[]") {
        return Err("invalid '" + key + "' '" + u + "' (expected http://<host>:<port> with no path; the path is the vdir param)")
    }
    Ok(())
}

fn check_vdir(key: string, v: string) -> Result[unit, string] {
    if v == "" || !common::only_chars(v, "_-") { return Err("invalid '" + key + "' '" + v + "' (letters, digits, _ and -)") }
    Ok(())
}

fn want(params: Value) -> Result[Want, string] {
    if sys::family() != "windows" { return Err("mssql.reporting_services_config is Windows only") }
    let inst = common::param_str(params, "instance", "SSRS")
    if inst == "" { return Err("'instance' must not be empty") }
    common::check_instance(inst)?
    let db_server = common::param_str(params, "database_server", "localhost")
    let db_name = common::param_str(params, "database_name", "ReportServer")
    if db_server == "" || db_server.contains("'") || db_server.contains(";") { return Err("invalid 'database_server' '" + db_server + "'") }
    if db_name == "" || !common::only_chars(db_name, "_-$") { return Err("invalid 'database_name' '" + db_name + "' (letters, digits, _, - and $)") }
    let cred = common::param_str(params, "credentials", "service_account")
    let logon_type = if cred == "windows" { 0 } else if cred == "sql" { 1 } else if cred == "service_account" { 2 } else {
        return Err("invalid 'credentials' value '" + cred + "' (expected :service_account, :windows or :sql)")
    }
    let db_user = common::param_str(params, "db_user", "")
    let db_password = common::param_str(params, "db_password", "")
    if logon_type != 2 && (db_user == "" || db_password == "") { return Err("credentials = :" + cred + " needs 'db_user' and 'db_password'") }
    let w = Want {
        inst: inst, db_server: db_server, db_name: db_name, cred: cred, logon_type: logon_type,
        db_user: db_user, db_password: db_password,
        ws_url: common::param_str(params, "web_service_url", "http://+:80"),
        ws_vdir: common::param_str(params, "web_service_vdir", "ReportServer"),
        portal_url: common::param_str(params, "web_portal_url", "http://+:80"),
        portal_vdir: common::param_str(params, "web_portal_vdir", "Reports"),
        account: common::param_str(params, "service_account", ""),
        password: common::param_str(params, "service_password", ""),
    }
    check_url("web_service_url", w.ws_url)?
    check_url("web_portal_url", w.portal_url)?
    check_vdir("web_service_vdir", w.ws_vdir)?
    check_vdir("web_portal_vdir", w.portal_vdir)?
    common::no_newlines("service_account", w.account)?
    common::no_newlines("db_user", w.db_user)?
    if w.account != "" && !builtin_account(w.account) && w.password == "" {
        return Err("'service_account' " + w.account + " is not a built-in account, so it needs 'service_password'")
    }
    Ok(w)
}

// Virtual and built-in accounts the provider sets without a password.
fn builtin_account(a: string) -> bool {
    let l = a.to_lower()
    l.starts_with("nt service\\") || l == "nt authority\\networkservice" || l == "nt authority\\network service" ||
        l == "nt authority\\localservice" || l == "nt authority\\local service" || l == "nt authority\\system" || l == "localsystem"
}

// The SQL connection to the catalogue server, for the database and rights work.
fn sql_conn(params: Value, w: Want) -> Value {
    Value::Map(#{
        "server": Value::String(w.db_server),
        "sql_user": Value::String(common::param_str(params, "sql_user", "")),
        "sql_password": Value::String(common::param_str(params, "sql_password", "")),
        "trust_server_certificate": Value::Bool(common::param_bool(params, "trust_server_certificate", true))
    })
}

// The login the report server reaches the catalogue as: db_user, or the
// service identity (its machine account when the catalogue is remote and the
// identity is a built-in or virtual one).
fn rights_login(w: Want, st: Value) -> string {
    if w.logon_type != 2 { return w.db_user }
    let id = ssrs::str_of(st, "identity_actual")
    if !ssrs::is_local_server(w.db_server) && builtin_account(id) && !id.to_lower().starts_with("nt service\\") {
        return ssrs::str_of(st, "user_domain") + "\\" + ssrs::str_of(st, "computer") + "$"
    }
    sql_login_name(id)
}

// The provider spells built-in accounts NT Authority\NetworkService; SQL
// Server only resolves NT AUTHORITY\NETWORK SERVICE.
fn sql_login_name(a: string) -> string {
    let l = a.to_lower().replace(" ", "")
    if l == "ntauthority\\networkservice" { return "NT AUTHORITY\\NETWORK SERVICE" }
    if l == "ntauthority\\localservice" { return "NT AUTHORITY\\LOCAL SERVICE" }
    if l == "ntauthority\\system" || l == "localsystem" { return "NT AUTHORITY\\SYSTEM" }
    a
}

fn db_exists(params: Value, w: Want) -> Result[bool, string] {
    Ok(common::run_scalar(sql_conn(params, w), "SELECT CASE WHEN DB_ID(" + common::tsql_lit(w.db_name) + ") IS NULL THEN 0 ELSE 1 END;")? == "1")
}

fn rights_ok(params: Value, w: Want, st: Value) -> Result[bool, string] {
    let db = common::tsql_id(w.db_name)
    let q = "SELECT CASE WHEN EXISTS (SELECT 1 FROM " + db + ".sys.database_role_members rm " +
        "JOIN " + db + ".sys.database_principals r ON r.principal_id = rm.role_principal_id " +
        "JOIN " + db + ".sys.database_principals u ON u.principal_id = rm.member_principal_id " +
        "WHERE r.name = N'RSExecRole' AND u.sid = SUSER_SID(" + common::tsql_lit(rights_login(w, st)) + ")) THEN 1 ELSE 0 END;"
    Ok(common::run_scalar(sql_conn(params, w), q)? == "1")
}

fn revision(inst: string, name: string) -> Result[string, string] {
    if let Some(v) = registry::read(marker_key(inst), name)? { return Ok(v.as_string().unwrap_or("")) }
    Ok("")
}

// Everything that differs, in the order apply fixes it.
fn drift(params: Value, w: Want, st: Value) -> Result[List[string], string] {
    let out = []
    if w.account != "" {
        if ssrs::str_of(st, "identity_configured").to_lower() != w.account.to_lower() { out.push("service_account") }
        else if !builtin_account(w.account) && revision(w.inst, "service_password_revision")? != common::param_str(params, "service_password_revision", "") { out.push("service_password") }
    }
    if !db_exists(params, w)? {
        out.push("database")
        out.push("rights")
    } else if !rights_ok(params, w, st)? {
        out.push("rights")
    }
    let conn_differs = ssrs::str_of(st, "db_server").to_lower() != w.db_server.to_lower() ||
        ssrs::str_of(st, "db_name").to_lower() != w.db_name.to_lower() ||
        ssrs::str_of(st, "db_logon_type") != str(w.logon_type) ||
        (w.logon_type != 2 && ssrs::str_of(st, "db_logon_account").to_lower() != w.db_user.to_lower())
    if conn_differs { out.push("database_connection") }
    else if w.logon_type != 2 && revision(w.inst, "db_password_revision")? != common::param_str(params, "db_password_revision", "") { out.push("db_password") }
    let web_app = ssrs::str_of(st, "web_app")
    if ssrs::str_of(st, "vdir_ws") != w.ws_vdir { out.push("web_service_vdir") }
    let ws_urls = ssrs::urls_for(st, "ReportServerWebService")
    if ws_urls.len() != 1 || ws_urls.get(0).unwrap_or("").to_lower() != w.ws_url.to_lower() { out.push("web_service_url") }
    if ssrs::str_of(st, "vdir_portal") != w.portal_vdir { out.push("web_portal_vdir") }
    let portal_urls = ssrs::urls_for(st, web_app)
    if portal_urls.len() != 1 || portal_urls.get(0).unwrap_or("").to_lower() != w.portal_url.to_lower() { out.push("web_portal_url") }
    if !ssrs::bool_of(st, "ws_enabled") || !ssrs::bool_of(st, "portal_enabled") || !ssrs::bool_of(st, "svc_enabled") { out.push("service_state") }
    if !ssrs::bool_of(st, "initialized") { out.push("initialized") }
    Ok(out)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let w = want(params)?
    let st = ssrs::state(w.inst)?
    let d = drift(params, w, st)?
    if d.is_empty() { return Ok(CheckResult::AlreadyConfigured) }
    log::info("Reporting Services " + w.inst + " differs in: " + d.join(", "))
    Ok(CheckResult::NotConfigured)
}

// Makes `url` the only one reserved for `app` under `vdir`. The virtual
// directory can only change while no URL is reserved for the application, so
// a vdir change releases its URLs first.
fn urls_ps(app: string, vdir: string, url: string, have_vdir: string, have: List[string]) -> string {
    let s = ""
    let keep = have.filter(|u| u.to_lower() == url.to_lower() && have_vdir == vdir)
    for u in have {
        if !keep.contains(u) {
            s = s + "Assert-CwWmi ($cfg.RemoveURL(" + common::ps_q(app) + ", " + common::ps_q(u) + ", 1033)) " + common::ps_q("releasing " + u + " for " + app) + "\n"
        }
    }
    if have_vdir != vdir {
        s = s + "Assert-CwWmi ($cfg.SetVirtualDirectory(" + common::ps_q(app) + ", " + common::ps_q(vdir) + ", 1033)) " + common::ps_q("setting the " + app + " virtual directory") + "\n"
    }
    if keep.is_empty() {
        s = s + "Assert-CwWmi ($cfg.ReserveURL(" + common::ps_q(app) + ", " + common::ps_q(url) + ", 1033)) " + common::ps_q("reserving " + url + " for " + app) + "\n"
    }
    s
}

// Runs a script the provider generates (database creation or rights) on the
// catalogue server. It goes to sqlcmd on stdin, so it never reaches a
// command line or the disk.
fn run_generated(params: Value, w: Want, what: string, ps_call: string) -> Result[unit, string] {
    let body = "$r = " + ps_call + "\nAssert-CwWmi $r " + common::ps_q(what) + "\n[Console]::Out.Write($r.Script)"
    let sql = ssrs::run(w.inst, what, body, #{})?
    if sql.trim() == "" { return Err(what + " returned an empty script") }
    log::info("running the " + what + " on " + w.db_server)
    common::run_exec(sql_conn(params, w), sql)
}

fn local_url(u: string, vdir: string) -> string {
    u.replace("://+", "://localhost").replace("://*", "://localhost") + "/" + vdir
}

// Waits for the web service and then the web portal, which starts later.
fn wait_for_web(w: Want, secs: int) -> Result[unit, string] {
    let start = time::instant()
    wait_for_url(local_url(w.ws_url, w.ws_vdir), start, secs)?
    wait_for_url(local_url(w.portal_url, w.portal_vdir), start, secs)
}

fn wait_for_url(url: string, start: float, secs: int) -> Result[unit, string] {
    let last = ""
    loop {
        match http::get(url, Value::Map(#{ "timeout": Value::Int(30), "redirects": Value::Bool(false) })) {
            // Any answer but 503 means the web service is up: without
            // credentials it answers 401.
            Ok(r) => {
                if r.status != 503 && r.status != 0 { return Ok(()) }
                last = "HTTP " + str(r.status)
            }
            // http::get reports a non-2xx answer as an error, "http status: N".
            Err(e) => {
                if e.starts_with("http status: ") && !e.contains("503") { return Ok(()) }
                last = e
            }
        }
        if time::elapsed(start) > float(secs) { return Err("the report server at " + url + " did not answer within " + str(secs) + "s: " + last) }
        time::sleep(5000)
    }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let w = want(params)?
    let st = ssrs::state(w.inst)?
    let d = drift(params, w, st)?
    if d.is_empty() { return Ok(ApplyResult::Success) }
    log::info("configuring Reporting Services " + w.inst + ": " + d.join(", "))

    if d.contains("service_account") || d.contains("service_password") {
        let builtin = builtin_account(w.account)
        let body = "Assert-CwWmi ($cfg.SetWindowsServiceIdentity(" + (if builtin { "$true" } else { "$false" }) + ", " +
            common::ps_q(w.account) + ", " + (if builtin { "''" } else { "$env:CW_SVC_PASSWORD" }) + ")) 'setting the service account'"
        ssrs::call(w.inst, "setting the Reporting Services service account", body, #{ "CW_SVC_PASSWORD": Value::String(w.password) })?
        if !builtin { registry::write(marker_key(w.inst), "service_password_revision", Value::String(common::param_str(params, "service_password_revision", "")), "sz")? }
    }
    // The identity may have changed, so the rights below go to the new one.
    let st2 = if d.contains("service_account") { ssrs::state(w.inst)? } else { st }

    if d.contains("database") {
        if db_exists(params, w)? { return Err("database " + w.db_name + " appeared on " + w.db_server + " while configuring; run again") }
        run_generated(params, w, "database creation script",
            "$cfg.GenerateDatabaseCreationScript(" + common::ps_q(w.db_name) + ", 1033, $false)")?
    }
    if d.contains("rights") {
        let remote = if ssrs::is_local_server(w.db_server) { "$false" } else { "$true" }
        let windows_user = if w.logon_type == 1 { "$false" } else { "$true" }
        let user = if w.logon_type == 2 { ssrs::str_of(st2, "identity_actual") } else { w.db_user }
        run_generated(params, w, "database rights script",
            "$cfg.GenerateDatabaseRightsScript(" + common::ps_q(user) + ", " + common::ps_q(w.db_name) + ", " + remote + ", " + windows_user + ")")?
    }
    if d.contains("database_connection") || d.contains("db_password") {
        let user = if w.logon_type == 2 { "''" } else { common::ps_q(w.db_user) }
        let pw = if w.logon_type == 2 { "''" } else { "$env:CW_DB_PASSWORD" }
        let body = "Assert-CwWmi ($cfg.SetDatabaseConnection(" + common::ps_q(w.db_server) + ", " + common::ps_q(w.db_name) + ", " +
            str(w.logon_type) + ", " + user + ", " + pw + ")) 'setting the database connection'"
        ssrs::call(w.inst, "setting the Reporting Services database connection", body, #{ "CW_DB_PASSWORD": Value::String(w.db_password) })?
        if w.logon_type != 2 { registry::write(marker_key(w.inst), "db_password_revision", Value::String(common::param_str(params, "db_password_revision", "")), "sz")? }
    }

    let web_app = ssrs::str_of(st2, "web_app")
    let urls = ""
    if d.contains("web_service_vdir") || d.contains("web_service_url") {
        urls = urls + urls_ps("ReportServerWebService", w.ws_vdir, w.ws_url, ssrs::str_of(st2, "vdir_ws"), ssrs::urls_for(st2, "ReportServerWebService"))
    }
    if d.contains("web_portal_vdir") || d.contains("web_portal_url") {
        urls = urls + urls_ps(web_app, w.portal_vdir, w.portal_url, ssrs::str_of(st2, "vdir_portal"), ssrs::urls_for(st2, web_app))
    }
    if urls != "" { ssrs::call(w.inst, "reserving the Reporting Services URLs", urls, #{})? }

    if d.contains("service_state") {
        ssrs::call(w.inst, "enabling the report server", "Assert-CwWmi ($cfg.SetServiceState($true, $true, $true)) 'enabling the web service, web portal and service'", #{})?
    }

    // The service reads its configuration at start.
    let svc = ssrs::str_of(st2, "service")
    let only_init = d.len() == 1 && d.contains("initialized")
    if !only_init && svc != "" {
        log::info("restarting " + svc)
        service::restart(svc, Value::Map(#{ "timeout": Value::Int(300) }))?
    }
    let timeout = common::param_int(params, "wait_timeout", 300)
    wait_for_web(w, timeout)?

    let st3 = ssrs::state(w.inst)?
    if !ssrs::bool_of(st3, "initialized") {
        log::info("initializing the report server")
        ssrs::call(w.inst, "initializing the report server", "Assert-CwWmi ($cfg.InitializeReportServer($cfg.InstallationID)) 'InitializeReportServer'", #{})?
    }
    Ok(ApplyResult::Success)
}
