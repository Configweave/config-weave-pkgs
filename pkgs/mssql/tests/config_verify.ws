use value
use fs
use shell

// Runs inside the SQL Server container after the three-run protocol. Confirms
// the resources actually landed, using the SA login the test setup configured.
fn q1(query: string) -> Result[string, string] {
    let f = fs::temp_file()?
    fs::write(f, "SET NOCOUNT ON;\n" + query)?
    let cmd = "/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -P \"Str0ng!Passw0rd\" -C -h -1 -W -b -r 1 -i \"" + f + "\""
    let out = shell::run(cmd, Value::Null)?
    fs::delete(f)?
    if !out.success { return Err("sqlcmd failed: " + out.stderr.trim() + " " + out.stdout.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    // The gathered instance_info reports a version string.
    let ver_ok = if let Some(info) = facts.get("info") {
        if let Some(v) = info.get("version") {
            if let Some(s) = v.as_string() { s != "" } else { false }
        } else { false }
    } else { false }
    if !ver_ok { return Ok(false) }

    let db = q1("SELECT CASE WHEN DB_ID(N'weave_app_db') IS NOT NULL THEN '1' ELSE '0' END;")?
    let cdc = q1("SELECT CAST(is_cdc_enabled AS varchar(1)) FROM sys.databases WHERE name = N'weave_app_db';")?
    let login = q1("SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'weave_app') THEN '1' ELSE '0' END;")?
    let user = q1("USE weave_app_db; SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'weave_app') THEN '1' ELSE '0' END;")?
    let mem = q1("SELECT CAST(value_in_use AS varchar(16)) FROM sys.configurations WHERE name = N'max server memory (MB)';")?
    if !(db == "1" && cdc == "1" && login == "1" && user == "1" && mem == "2048") { return Ok(false) }

    // The absent resources really dropped the pre-seeded principals/objects…
    let drop_login = q1("SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'cw_drop_login') THEN '1' ELSE '0' END;")?
    let drop_db = q1("SELECT CASE WHEN DB_ID(N'cw_drop_db') IS NOT NULL THEN '1' ELSE '0' END;")?
    let drop_job = q1("SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'cw_drop_job') THEN '1' ELSE '0' END;")?
    // …and the create resources landed: the Agent job plus a CDC capture instance.
    let job = q1("SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'cw_job') THEN '1' ELSE '0' END;")?
    let capture = q1("USE cw_cdc_db; SELECT CASE WHEN EXISTS (SELECT 1 FROM cdc.change_tables WHERE capture_instance = N'dbo_cw_rows') THEN '1' ELSE '0' END;")?
    Ok(drop_login == "0" && drop_db == "0" && drop_job == "0" && job == "1" && capture == "1")
}
