use value
use fs
use shell
use sys

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}
fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
    fallback
}

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
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

fn norm_rm(rm: string) -> string { rm.trim().to_upper().replace(" ", "_") }

// Returns "" when absent, otherwise the collation name so we can detect drift.
fn current_collation(params: Value, name: string) -> Result[string, string] {
    let q = "SELECT ISNULL((SELECT collation_name FROM sys.databases WHERE name = " + tsql_lit(name) + "), '');"
    run_scalar(params, q)
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        let q = "SELECT CASE WHEN DB_ID(" + tsql_lit(name) + ") IS NULL THEN 'GONE' ELSE 'PRESENT' END;"
        let r = run_scalar(params, q)?
        if r == "GONE" { return Ok(CheckResult::AlreadyConfigured) }
        return Ok(CheckResult::NotConfigured)
    }
    let rm = norm_rm(param_str(params, "recovery_model", ""))
    let coll = param_str(params, "collation", "")
    let owner = param_str(params, "owner", "")
    let complvl = param_int(params, "compatibility_level", 0)

    // Collation can only be set at CREATE; treat an existing mismatch as an error.
    if coll != "" {
        let have = current_collation(params, name)?
        if have != "" && have != coll {
            return Err("database '" + name + "' exists with collation '" + have + "'; collation cannot be changed in place")
        }
    }

    let rm_clause = if rm != "" { " AND d.recovery_model_desc = " + tsql_lit(rm) } else { "" }
    let cl_clause = if complvl != 0 { " AND d.compatibility_level = " + str(complvl) } else { "" }
    let owner_clause = if owner != "" { " AND SUSER_SNAME(d.owner_sid) = " + tsql_lit(owner) } else { "" }
    let q = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.databases d WHERE d.name = " + tsql_lit(name) +
        rm_clause + cl_clause + owner_clause + ") THEN 'CONFIGURED' ELSE 'MISSING' END;"
    let r = run_scalar(params, q)?
    if r == "CONFIGURED" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let id = tsql_id(name)
    if !want_present(params)? {
        let batch = "IF DB_ID(" + tsql_lit(name) + ") IS NOT NULL BEGIN " +
            "ALTER DATABASE " + id + " SET SINGLE_USER WITH ROLLBACK IMMEDIATE; " +
            "DROP DATABASE " + id + "; END;"
        run_exec(params, batch)?
        return Ok(ApplyResult::Success)
    }
    let coll = param_str(params, "collation", "")
    let coll_clause = if coll != "" { " COLLATE " + coll } else { "" }
    let create = "IF DB_ID(" + tsql_lit(name) + ") IS NULL CREATE DATABASE " + id + coll_clause + "; "

    let rm = norm_rm(param_str(params, "recovery_model", ""))
    let rm_stmt = if rm != "" { "ALTER DATABASE " + id + " SET RECOVERY " + rm + " WITH NO_WAIT; " } else { "" }
    let complvl = param_int(params, "compatibility_level", 0)
    let cl_stmt = if complvl != 0 { "ALTER DATABASE " + id + " SET COMPATIBILITY_LEVEL = " + str(complvl) + "; " } else { "" }
    let owner = param_str(params, "owner", "")
    let owner_stmt = if owner != "" { "ALTER AUTHORIZATION ON DATABASE::" + id + " TO " + tsql_id(owner) + "; " } else { "" }

    run_exec(params, create + rm_stmt + cl_stmt + owner_stmt)?
    Ok(ApplyResult::Success)
}
