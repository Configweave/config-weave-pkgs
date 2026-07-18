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

fn want_present(params: Value) -> Result[bool, string] {
    let e = param_str(params, "ensure", "present")
    if e == "present" { return Ok(true) }
    if e == "absent" { return Ok(false) }
    Err("invalid 'ensure' value '" + e + "' (expected :present or :absent)")
}

fn dq(s: string) -> string { "\"" + s.replace("\"", "\"\"") + "\"" }
fn tsql_lit(s: string) -> string { "N'" + s.replace("'", "''") + "'" }

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

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    let q = "SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = " + tsql_lit(name) +
        ") THEN 'PRESENT' ELSE 'GONE' END;"
    let r = run_scalar(params, q)?
    if (r == "PRESENT") == want_present(params)? { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !want_present(params)? {
        let batch = "IF EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = " + tsql_lit(name) + ") " +
            "EXEC msdb.dbo.sp_delete_job @job_name = " + tsql_lit(name) + ";"
        run_exec(params, batch)?
        return Ok(ApplyResult::Success)
    }
    let command = param_str(params, "command", "")
    if command == "" { return Err("missing 'command' parameter") }
    let subsystem = param_str(params, "subsystem", "TSQL")
    let step_name = param_str(params, "step_name", "Step 1")
    let enabled = if param_bool(params, "enabled", true) { "1" } else { "0" }
    let desc = param_str(params, "description", "")
    let owner = param_str(params, "owner", "")
    let owner_arg = if owner != "" { ", @owner_login_name = " + tsql_lit(owner) } else { "" }
    let db_arg = if subsystem == "TSQL" { ", @database_name = " + tsql_lit(param_str(params, "database", "master")) } else { "" }

    let batch = "IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = " + tsql_lit(name) + ") " +
        "BEGIN " +
        "EXEC msdb.dbo.sp_add_job @job_name = " + tsql_lit(name) + ", @enabled = " + enabled +
        ", @description = " + tsql_lit(desc) + owner_arg + "; " +
        "EXEC msdb.dbo.sp_add_jobstep @job_name = " + tsql_lit(name) + ", @step_name = " + tsql_lit(step_name) +
        ", @subsystem = " + tsql_lit(subsystem) + ", @command = " + tsql_lit(command) + db_arg + "; " +
        "EXEC msdb.dbo.sp_add_jobserver @job_name = " + tsql_lit(name) + ", @server_name = N'(LOCAL)'; " +
        "END;"
    run_exec(params, batch)?
    Ok(ApplyResult::Success)
}
