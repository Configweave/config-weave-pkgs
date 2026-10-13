use value
use shell

// Runs one query against the local engine as sa and returns its trimmed output.
fn q1(query: string) -> Result[string, string] {
    let out = shell::run("/opt/mssql-tools18/bin/sqlcmd -S localhost -U sa -C -h -1 -W -b -r 1", Value::Map(#{
        "stdin": Value::String("SET NOCOUNT ON;\n" + query + "\n"),
        "env": Value::Map(#{ "SQLCMDPASSWORD": Value::String("Str0ng!Passw0rd") })
    }))?
    if !out.success { return Err("sqlcmd failed: " + out.stderr.trim() + " " + out.stdout.trim()) }
    Ok(out.stdout.trim())
}

// Fails verify with a message naming the property that is wrong.
fn expect(what: string, got: string, want: string) -> Result[unit, string] {
    if got != want { return Err(what + ": expected '" + want + "', got '" + got + "'") }
    Ok(())
}

// Runs inside the SQL Server container after the three-run protocol and
// confirms the resources actually landed. A failed assertion fails verify
// with the property that was wrong.
fn verify(facts: Value) -> Result[bool, string] {
    assertions(facts)?
    Ok(true)
}

fn assertions(facts: Value) -> Result[bool, string] {
    // The gathered instance_info reports a version string.
    let ver = if let Some(info) = facts.get("info") {
        if let Some(v) = info.get("version") { v.as_string().unwrap_or("") } else { "" }
    } else { "" }
    if ver == "" { return Err("instance_info gathered no version") }

    expect("weave_app_db exists", q1("SELECT CASE WHEN DB_ID(N'weave_app_db') IS NOT NULL THEN '1' ELSE '0' END;")?, "1")?
    expect("weave_app_db recovery model", q1("SELECT recovery_model_desc FROM sys.databases WHERE name = N'weave_app_db';")?, "SIMPLE")?
    expect("weave_app_db CDC", q1("SELECT CAST(is_cdc_enabled AS varchar(1)) FROM sys.databases WHERE name = N'weave_app_db';")?, "1")?
    expect("weave_app login", q1("SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.sql_logins WHERE name = N'weave_app' AND PWDCOMPARE(N'L0gin!Passw0rd', password_hash) = 1) THEN '1' ELSE '0' END;")?, "1")?
    expect("weave_app user", q1("USE weave_app_db; SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.database_principals WHERE name = N'weave_app' AND SUSER_SNAME(sid) = N'weave_app') THEN '1' ELSE '0' END;")?, "1")?
    expect("weave_app in db_datareader", q1("USE weave_app_db; SELECT CAST(IS_ROLEMEMBER(N'db_datareader', N'weave_app') AS varchar(2));")?, "1")?
    expect("weave_app in db_datawriter", q1("USE weave_app_db; SELECT CAST(IS_ROLEMEMBER(N'db_datawriter', N'weave_app') AS varchar(2));")?, "1")?
    expect("max server memory", q1("SELECT CAST(value_in_use AS varchar(16)) FROM sys.configurations WHERE name = N'max server memory (MB)';")?, "2048")?

    // The absent resources really dropped the pre-seeded principals and objects...
    expect("cw_drop_login gone", q1("SELECT CASE WHEN EXISTS (SELECT 1 FROM sys.server_principals WHERE name = N'cw_drop_login') THEN '1' ELSE '0' END;")?, "0")?
    expect("cw_drop_db gone", q1("SELECT CASE WHEN DB_ID(N'cw_drop_db') IS NOT NULL THEN '1' ELSE '0' END;")?, "0")?
    expect("cw_drop_job gone", q1("SELECT CASE WHEN EXISTS (SELECT 1 FROM msdb.dbo.sysjobs WHERE name = N'cw_drop_job') THEN '1' ELSE '0' END;")?, "0")?
    // ...and the create resources landed: the Agent job plus a CDC capture instance.
    expect("cw_job step", q1("SELECT CAST(COUNT(*) AS varchar(4)) FROM msdb.dbo.sysjobsteps s JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id WHERE j.name = N'cw_job' AND s.command = N'SELECT 1';")?, "1")?
    expect("dbo_cw_rows capture instance", q1("USE cw_cdc_db; SELECT CASE WHEN EXISTS (SELECT 1 FROM cdc.change_tables WHERE capture_instance = N'dbo_cw_rows') THEN '1' ELSE '0' END;")?, "1")?
    Ok(true)
}
