use value
use fs
use shell
use sys
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}
fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
}

fn dq(s: string) -> string { "\"" + s.replace("\"", "\"\"") + "\"" }
fn tsql_lit(s: string) -> string { "N'" + s.replace("'", "''") + "'" }
fn tsql_id(s: string) -> string { "[" + s.replace("]", "]]") + "]" }

fn sqlcmd_bin() -> string {
    if sys::family() == "windows" {
        if fs::exists("C:\\Program Files\\sqlcmd\\sqlcmd.exe") { return "C:\\Program Files\\sqlcmd\\sqlcmd.exe" }
        for v in ["170", "160", "150", "130"] {
            let p = "C:\\Program Files\\Microsoft SQL Server\\Client SDK\\ODBC\\" + v + "\\Tools\\Binn\\SQLCMD.EXE"
            if fs::exists(p) { return p }
        }
        return "sqlcmd"
    }
    if fs::exists("/opt/mssql-tools18/bin/sqlcmd") { return "/opt/mssql-tools18/bin/sqlcmd" }
    if fs::exists("/opt/mssql-tools/bin/sqlcmd") { return "/opt/mssql-tools/bin/sqlcmd" }
    "sqlcmd"
}

fn conn_args(params: Value) -> string {
    let server = param_str(params, "server", "")
    let inst = param_str(params, "instance", "")
    let base = if server != "" { server } else if sys::family() == "windows" { "(local)" } else { "localhost" }
    let target = if inst != "" { base + "\\" + inst } else { base }
    let user = param_str(params, "sql_user", "")
    let auth = if user != "" { " -U " + dq(user) + " -P " + dq(param_str(params, "sql_password", "")) } else { " -E" }
    " -S " + dq(target) + " -C -l 30" + auth
}

fn run_scalar(params: Value, query: string) -> Result[string, string] {
    let f = fs::temp_file()?
    fs::write(f, "SET NOCOUNT ON;\n" + query)?
    let out = shell::run(dq(sqlcmd_bin()) + conn_args(params) + " -h -1 -W -b -r 1 -i " + dq(f), Value::Null)?
    fs::delete(f)?
    if !out.success { return Err("sqlcmd failed: " + out.stderr.trim() + " " + out.stdout.trim()) }
    Ok(out.stdout.trim())
}

fn run_exec(params: Value, batch: string) -> Result[unit, string] {
    let f = fs::temp_file()?
    fs::write(f, "SET NOCOUNT ON;\n" + batch)?
    let out = shell::run(dq(sqlcmd_bin()) + conn_args(params) + " -b -r 1 -i " + dq(f), Value::Null)?
    fs::delete(f)?
    if !out.success { return Err("sqlcmd exec failed: " + out.stderr.trim() + " " + out.stdout.trim()) }
    Ok(())
}

fn agent_running(params: Value) -> bool {
    let q = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.dm_server_services WHERE servicename LIKE 'SQL Server Agent%' AND status_desc = 'Running') THEN '1' ELSE '0' END;"
    if let Ok(r) = run_scalar(params, q) { return r == "1" }
    false
}

fn check(params: Value) -> Result[CheckResult, string] {
    let db = param_str(params, "database", "")
    if db == "" { return Err("missing 'database' parameter") }
    let want = if param_bool(params, "enabled", true) { "1" } else { "0" }
    let q = "SELECT CASE WHEN is_cdc_enabled = " + want + " THEN 'CONFIGURED' ELSE 'MISSING' END FROM sys.databases WHERE name = " + tsql_lit(db) + ";"
    let r = run_scalar(params, q)?
    // The database may not exist yet during a check-only run (its creation is a
    // separate, earlier step) — report not-configured rather than erroring.
    if r == "" { return Ok(CheckResult::NotConfigured) }
    if r == "CONFIGURED" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let db = param_str(params, "database", "")
    if db == "" { return Err("missing 'database' parameter") }
    let enabled = param_bool(params, "enabled", true)
    if enabled && !agent_running(params) {
        log::warn("SQL Server Agent is not running; CDC capture jobs will not run until it is started")
    }
    let batch = if enabled {
        "USE " + tsql_id(db) + "; " +
            "IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 0 EXEC sys.sp_cdc_enable_db;"
    } else {
        "USE " + tsql_id(db) + "; " +
            "IF (SELECT is_cdc_enabled FROM sys.databases WHERE name = DB_NAME()) = 1 EXEC sys.sp_cdc_disable_db;"
    }
    run_exec(params, batch)?
    Ok(ApplyResult::Success)
}
