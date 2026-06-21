use value
use fs
use shell
use sys

fn param_str(params: Value, key: string, fallback: string) -> string {
    if let Some(v) = params.get(key) { if let Some(s) = v.as_string() { return s } }
    fallback
}

fn dq(s: string) -> string { "\"" + s.replace("\"", "\"\"") + "\"" }

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

fn prop(name: string) -> string {
    "ISNULL(CAST(SERVERPROPERTY('" + name + "') AS nvarchar(128)), '')"
}

fn gather(params: Value) -> Result[Value, string] {
    let q = "SELECT " + prop("ProductVersion") + " + '|' + " + prop("Edition") + " + '|' + " +
        prop("ProductLevel") + " + '|' + " + prop("EngineEdition") + " + '|' + " +
        prop("IsHadrEnabled") + " + '|' + " + prop("Collation") + " + '|' + " + prop("MachineName") + ";"
    let raw = run_scalar(params, q)?
    let f = raw.split("|")
    Ok(Value::Map(#{
        "version": Value::String(f.get(0).unwrap_or("")),
        "edition": Value::String(f.get(1).unwrap_or("")),
        "product_level": Value::String(f.get(2).unwrap_or("")),
        "engine_edition": Value::String(f.get(3).unwrap_or("")),
        "hadr_enabled": Value::String(f.get(4).unwrap_or("")),
        "collation": Value::String(f.get(5).unwrap_or("")),
        "machine": Value::String(f.get(6).unwrap_or(""))
    }))
}
