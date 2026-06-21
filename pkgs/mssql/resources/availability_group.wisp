use value
use fs
use shell
use sys
use log

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}
fn param_int(params: Value, key: string, fallback: int) -> int {
    if let Some(v) = params.get(key) { if let Some(i) = v.as_int() { return i } }
    fallback
}

fn dq(s: string) -> string { "\"" + s.replace("\"", "\"\"") + "\"" }
fn tsql_lit(s: string) -> string { "N'" + s.replace("'", "''") + "'" }
fn tsql_id(s: string) -> string { "[" + s.replace("]", "]]") + "]" }
fn ps_q(s: string) -> string { "'" + s.replace("'", "''") + "'" }

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

fn hadr_enabled(params: Value) -> Result[bool, string] {
    let r = run_scalar(params, "SELECT CAST(SERVERPROPERTY('IsHadrEnabled') AS int);")?
    Ok(r == "1")
}

fn enable_hadr(params: Value) -> Result[unit, string] {
    let inst = param_str(params, "instance_name", "MSSQLSERVER")
    if sys::family() == "windows" {
        let target = if inst == "MSSQLSERVER" { "$env:COMPUTERNAME" } else { "($env:COMPUTERNAME + '\\" + inst + "')" }
        let script = "Import-Module SqlServer -ErrorAction SilentlyContinue; " +
            "Enable-SqlAlwaysOn -ServerInstance " + target + " -Force"
        let out = shell::powershell(script, Value::Null)?
        if !out.success { return Err("Enable-SqlAlwaysOn failed: " + out.stderr.trim()) }
        return Ok(())
    }
    let set = shell::bash("/opt/mssql/bin/mssql-conf set hadr.hadrenabled 1", Value::Null)?
    if !set.success { return Err("mssql-conf set hadr failed: " + set.stderr.trim()) }
    let r = shell::bash("systemctl restart mssql-server", Value::Null)?
    if !r.success { return Err("restarting mssql-server failed: " + r.stderr.trim()) }
    Ok(())
}

fn check(params: Value) -> Result[CheckResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }
    if !hadr_enabled(params)? { return Ok(CheckResult::NotConfigured) }
    let q = "SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = " + tsql_lit(name) +
        ") THEN 'CONFIGURED' ELSE 'MISSING' END;"
    let r = run_scalar(params, q)?
    if r == "CONFIGURED" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let name = param_str(params, "name", "")
    if name == "" { return Err("missing 'name' parameter") }

    // Phase 1: enabling HADR requires a service restart before the AG can be created.
    if !hadr_enabled(params)? {
        log::info("enabling Always On HADR (a service restart is required)")
        enable_hadr(params)?
        return Ok(ApplyResult::RebootRequired)
    }

    // Phase 2: create the mirroring endpoint and the availability group on the primary.
    let port = param_int(params, "endpoint_port", 5022)
    let ep = param_str(params, "endpoint_name", "Hadr_endpoint")
    let srv = run_scalar(params, "SELECT @@SERVERNAME;")?
    let host = run_scalar(params, "SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(128));")?
    let url = "TCP://" + host + ":" + str(port)

    let endpoint = "IF NOT EXISTS (SELECT 1 FROM sys.endpoints WHERE name = " + tsql_lit(ep) + ") " +
        "CREATE ENDPOINT " + tsql_id(ep) + " STATE = STARTED AS TCP (LISTENER_PORT = " + str(port) +
        ") FOR DATABASE_MIRRORING (ROLE = ALL); "
    let ag = "IF NOT EXISTS (SELECT 1 FROM sys.availability_groups WHERE name = " + tsql_lit(name) + ") " +
        "CREATE AVAILABILITY GROUP " + tsql_id(name) + " FOR REPLICA ON " + tsql_lit(srv) +
        " WITH (ENDPOINT_URL = " + tsql_lit(url) +
        ", AVAILABILITY_MODE = SYNCHRONOUS_COMMIT, FAILOVER_MODE = MANUAL); "
    run_exec(params, endpoint + ag)?
    Ok(ApplyResult::Success)
}
