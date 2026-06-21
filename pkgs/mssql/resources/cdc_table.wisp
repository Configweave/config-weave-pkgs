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

fn capture_name(params: Value) -> string {
    let ci = param_str(params, "capture_instance", "")
    if ci != "" { return ci }
    param_str(params, "schema", "dbo") + "_" + param_str(params, "table", "")
}

fn present_predicate(schema: string, table: string, ci: string) -> string {
    "EXISTS (SELECT 1 FROM cdc.change_tables ct " +
        "JOIN sys.tables t ON t.object_id = ct.source_object_id " +
        "JOIN sys.schemas s ON s.schema_id = t.schema_id " +
        "WHERE s.name = " + tsql_lit(schema) + " AND t.name = " + tsql_lit(table) +
        " AND ct.capture_instance = " + tsql_lit(ci) + ")"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let db = param_str(params, "database", "")
    let table = param_str(params, "table", "")
    if db == "" { return Err("missing 'database' parameter") }
    if table == "" { return Err("missing 'table' parameter") }
    let schema = param_str(params, "schema", "dbo")
    let ci = capture_name(params)
    // Without the database present and CDC enabled the cdc.change_tables catalog
    // does not exist; report not-configured rather than erroring on it.
    let pre = run_scalar(params, "SELECT CASE WHEN DB_ID(" + tsql_lit(db) + ") IS NOT NULL AND (SELECT ISNULL(is_cdc_enabled, 0) FROM sys.databases WHERE name = " + tsql_lit(db) + ") = 1 THEN '1' ELSE '0' END;")?
    if pre == "0" { return Ok(CheckResult::NotConfigured) }
    let q = "USE " + tsql_id(db) + "; SELECT CASE WHEN " + present_predicate(schema, table, ci) + " THEN 'CONFIGURED' ELSE 'MISSING' END;"
    let r = run_scalar(params, q)?
    if r == "CONFIGURED" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let db = param_str(params, "database", "")
    let table = param_str(params, "table", "")
    if db == "" { return Err("missing 'database' parameter") }
    if table == "" { return Err("missing 'table' parameter") }
    let schema = param_str(params, "schema", "dbo")
    let ci = capture_name(params)
    let role = param_str(params, "role_name", "")
    let role_arg = if role != "" { tsql_lit(role) } else { "NULL" }
    let net = if param_bool(params, "supports_net_changes", true) { "1" } else { "0" }

    // Guard against a database that has not had CDC enabled yet.
    let enabled = run_scalar(params, "SELECT CAST(is_cdc_enabled AS varchar(1)) FROM sys.databases WHERE name = " + tsql_lit(db) + ";")?
    if enabled != "1" {
        return Err("CDC is not enabled on database '" + db + "'; apply mssql.database_cdc first")
    }
    log::info("enabling CDC capture instance " + ci + " on " + schema + "." + table)

    let batch = "USE " + tsql_id(db) + "; " +
        "IF NOT " + present_predicate(schema, table, ci) + " " +
        "EXEC sys.sp_cdc_enable_table @source_schema = " + tsql_lit(schema) +
        ", @source_name = " + tsql_lit(table) +
        ", @role_name = " + role_arg +
        ", @capture_instance = " + tsql_lit(ci) +
        ", @supports_net_changes = " + net + ";"
    run_exec(params, batch)?
    Ok(ApplyResult::Success)
}
