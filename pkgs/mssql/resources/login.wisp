use value
use fs
use shell
use sys

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

fn role_member_predicate(role: string, login: string) -> string {
    "EXISTS (SELECT 1 FROM sys.server_role_members rm " +
        "JOIN sys.server_principals r ON r.principal_id = rm.role_principal_id AND r.name = " + tsql_lit(role) + " " +
        "JOIN sys.server_principals m ON m.principal_id = rm.member_principal_id AND m.name = " + tsql_lit(login) + ")"
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let db = param_str(params, "default_database", "master")
    let want_disabled = if param_bool(params, "enabled", true) { "0" } else { "1" }

    let head = "DECLARE @ok int = 1; " +
        "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = " + tsql_lit(name) +
        " AND is_disabled = " + want_disabled +
        " AND default_database_name = " + tsql_lit(db) +
        " AND type IN ('S','U','G')) SET @ok = 0; "
    let roles = csv(param_str(params, "server_roles", ""))
    let role_clauses = roles.fold("", |acc, role| acc + "IF @ok = 1 AND NOT " + role_member_predicate(role, name) + " SET @ok = 0; ")
    let q = head + role_clauses + "SELECT CASE WHEN @ok = 1 THEN 'CONFIGURED' ELSE 'MISSING' END;"
    let r = run_scalar(params, q)?
    if r == "CONFIGURED" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let auth = param_str(params, "auth", "windows")
    let db = param_str(params, "default_database", "master")
    let id = tsql_id(name)

    let create = if auth == "sql" {
        let pw = param_str(params, "password", "")
        if pw == "" { return Err("SQL logins require a 'password'") }
        let policy = if param_bool(params, "check_policy", false) { "ON" } else { "OFF" }
        "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = " + tsql_lit(name) + ") " +
            "CREATE LOGIN " + id + " WITH PASSWORD = " + tsql_lit(pw) +
            ", DEFAULT_DATABASE = " + tsql_id(db) + ", CHECK_POLICY = " + policy + "; "
    } else {
        "IF NOT EXISTS (SELECT 1 FROM sys.server_principals WHERE name = " + tsql_lit(name) + ") " +
            "CREATE LOGIN " + id + " FROM WINDOWS WITH DEFAULT_DATABASE = " + tsql_id(db) + "; "
    }

    let set_db = "ALTER LOGIN " + id + " WITH DEFAULT_DATABASE = " + tsql_id(db) + "; "
    let set_state = if param_bool(params, "enabled", true) {
        "ALTER LOGIN " + id + " ENABLE; "
    } else {
        "ALTER LOGIN " + id + " DISABLE; "
    }
    let force = if auth == "sql" && param_bool(params, "force_password", false) {
        "ALTER LOGIN " + id + " WITH PASSWORD = " + tsql_lit(param_str(params, "password", "")) + "; "
    } else { "" }

    let roles = csv(param_str(params, "server_roles", ""))
    let role_adds = roles.fold("", |acc, role|
        acc + "IF NOT " + role_member_predicate(role, name) +
            " ALTER SERVER ROLE " + tsql_id(role) + " ADD MEMBER " + id + "; ")

    run_exec(params, create + set_db + set_state + force + role_adds)?
    Ok(ApplyResult::Success)
}
