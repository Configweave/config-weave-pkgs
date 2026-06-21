use value
use fs
use shell
use sys

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn dq(s: string) -> string { "\"" + s.replace("\"", "\"\"") + "\"" }
fn tsql_lit(s: string) -> string { "N'" + s.replace("'", "''") + "'" }
fn tsql_id(s: string) -> string { "[" + s.replace("]", "]]") + "]" }

fn csv(s: string) -> List[string] {
    let out = []
    for part in s.split(",") {
        let t = part.trim()
        if t != "" { out.push(t) }
    }
    out
}

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

fn role_member_predicate(role: string, user: string) -> string {
    "EXISTS (SELECT 1 FROM sys.database_role_members rm " +
        "JOIN sys.database_principals r ON r.principal_id = rm.role_principal_id AND r.name = " + tsql_lit(role) + " " +
        "JOIN sys.database_principals m ON m.principal_id = rm.member_principal_id AND m.name = " + tsql_lit(user) + ")"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let db = param_str(params, "database", "")
    let name = param_str(params, "name", "")
    if db == "" { return Err("missing 'database' parameter") }
    if name == "" { return Err("missing 'name' parameter") }

    // The database may not exist yet during a check-only run (its creation is a
    // separate, earlier step) — report not-configured rather than erroring.
    let db_exists = run_scalar(params, "SELECT CASE WHEN DB_ID(" + tsql_lit(db) + ") IS NULL THEN '0' ELSE '1' END;")?
    if db_exists == "0" { return Ok(CheckResult::NotConfigured) }

    let head = "USE " + tsql_id(db) + "; DECLARE @ok int = 1; " +
        "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = " + tsql_lit(name) +
        " AND type IN ('S','U','G')) SET @ok = 0; "
    let roles = csv(param_str(params, "roles", ""))
    let role_clauses = roles.fold("", |acc, role| acc + "IF @ok = 1 AND NOT " + role_member_predicate(role, name) + " SET @ok = 0; ")
    let q = head + role_clauses + "SELECT CASE WHEN @ok = 1 THEN 'CONFIGURED' ELSE 'MISSING' END;"
    let r = run_scalar(params, q)?
    if r == "CONFIGURED" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let db = param_str(params, "database", "")
    let name = param_str(params, "name", "")
    let login = param_str(params, "login", "")
    if db == "" { return Err("missing 'database' parameter") }
    if name == "" { return Err("missing 'name' parameter") }
    if login == "" { return Err("missing 'login' parameter") }
    let schema = param_str(params, "default_schema", "dbo")
    let uid = tsql_id(name)

    let create = "USE " + tsql_id(db) + "; " +
        "IF NOT EXISTS (SELECT 1 FROM sys.database_principals WHERE name = " + tsql_lit(name) + ") " +
        "CREATE USER " + uid + " FOR LOGIN " + tsql_id(login) + " WITH DEFAULT_SCHEMA = " + tsql_id(schema) + "; "
    let roles = csv(param_str(params, "roles", ""))
    let role_adds = roles.fold("", |acc, role|
        acc + "IF IS_ROLEMEMBER(" + tsql_lit(role) + ", " + tsql_lit(name) + ") = 0 " +
            "ALTER ROLE " + tsql_id(role) + " ADD MEMBER " + uid + "; ")
    run_exec(params, create + role_adds)?
    Ok(ApplyResult::Success)
}
