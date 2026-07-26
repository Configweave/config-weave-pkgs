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
fn param_bool(params: Value, key: string, fallback: bool) -> bool {
    if let Some(v) = params.get(key) { if let Some(b) = v.as_bool() { return b } }
    fallback
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

fn link_predicate(profile: string, account: string) -> string {
    "EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profileaccount pa " +
        "JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id AND p.name = " + tsql_lit(profile) + " " +
        "JOIN msdb.dbo.sysmail_account a ON a.account_id = pa.account_id AND a.name = " + tsql_lit(account) + ")"
}

fn account_args(params: Value) -> string {
    let port = param_int(params, "port", 25)
    let ssl = if param_bool(params, "use_ssl", false) { "1" } else { "0" }
    let auth = param_str(params, "smtp_user", "")
    let auth_args = if auth != "" {
        ", @username = " + tsql_lit(auth) + ", @password = " + tsql_lit(param_str(params, "smtp_password", ""))
    } else { "" }
    "@email_address = " + tsql_lit(param_str(params, "from_address", "")) +
        ", @mailserver_name = " + tsql_lit(param_str(params, "smtp_server", "")) +
        ", @port = " + str(port) +
        ", @enable_ssl = " + ssl +
        auth_args
}

fn check(params: Value) -> Result[CheckResult, string] {
    let profile = param_str(params, "profile", "")
    let account = param_str(params, "account", "")
    if profile == "" { return Err("missing 'profile' parameter") }
    if account == "" { return Err("missing 'account' parameter") }
    let q = "SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = " + tsql_lit(profile) + ") " +
        "AND EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = " + tsql_lit(account) + ") " +
        "AND " + link_predicate(profile, account) + " THEN 'CONFIGURED' ELSE 'MISSING' END;"
    let r = run_scalar(params, q)?
    if r == "CONFIGURED" { Ok(CheckResult::AlreadyConfigured) } else { Ok(CheckResult::NotConfigured) }
}

fn apply(params: Value) -> Result[ApplyResult, string] {
    let profile = param_str(params, "profile", "")
    let account = param_str(params, "account", "")
    if profile == "" { return Err("missing 'profile' parameter") }
    if account == "" { return Err("missing 'account' parameter") }

    let enable = "EXEC sp_configure 'show advanced options', 1; RECONFIGURE; " +
        "EXEC sp_configure 'Database Mail XPs', 1; RECONFIGURE; "
    let add_account = "IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_account WHERE name = " + tsql_lit(account) + ") " +
        "EXEC msdb.dbo.sysmail_add_account_sp @account_name = " + tsql_lit(account) + ", " + account_args(params) + "; "
    let add_profile = "IF NOT EXISTS (SELECT 1 FROM msdb.dbo.sysmail_profile WHERE name = " + tsql_lit(profile) + ") " +
        "EXEC msdb.dbo.sysmail_add_profile_sp @profile_name = " + tsql_lit(profile) + "; "
    let add_link = "IF NOT " + link_predicate(profile, account) + " " +
        "EXEC msdb.dbo.sysmail_add_profileaccount_sp @profile_name = " + tsql_lit(profile) +
        ", @account_name = " + tsql_lit(account) + ", @sequence_number = 1; "
    let force = if param_bool(params, "force", false) {
        "EXEC msdb.dbo.sysmail_update_account_sp @account_name = " + tsql_lit(account) + ", " + account_args(params) + "; "
    } else { "" }

    run_exec(params, enable + add_account + add_profile + add_link + force)?
    Ok(ApplyResult::Success)
}
