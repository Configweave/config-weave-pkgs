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

// A failed assertion fails verify with the property that was wrong.
fn verify(facts: Value) -> Result[bool, string] {
    assertions()?
    Ok(true)
}

fn assertions() -> Result[unit, string] {
    expect("cost threshold", q1("SELECT CAST(value_in_use AS varchar(8)) FROM sys.configurations WHERE name = N'cost threshold for parallelism';")?, "40")?
    expect("show advanced options restored", q1("SELECT CAST(value AS varchar(8)) FROM sys.configurations WHERE name = N'show advanced options';")?, "0")?
    expect("fill factor configured", q1("SELECT CAST(value AS varchar(8)) FROM sys.configurations WHERE name = N'fill factor (%)';")?, "90")?
    expect("fill factor waits for a restart", q1("SELECT CAST(value_in_use AS varchar(8)) FROM sys.configurations WHERE name = N'fill factor (%)';")?, "0")?

    expect("cw_login", q1("SELECT CONCAT(is_disabled, '|', default_database_name COLLATE DATABASE_DEFAULT, '|', is_policy_checked, '|', PWDCOMPARE(N'N3w!Passw0rd12', password_hash), '|', IS_SRVROLEMEMBER(N'dbcreator', name)) FROM sys.sql_logins WHERE name = N'cw_login';")?, "0|master|0|1|1")?

    expect("cw_db", q1("SELECT CONCAT(recovery_model_desc COLLATE DATABASE_DEFAULT, '|', collation_name COLLATE DATABASE_DEFAULT, '|', SUSER_SNAME(owner_sid) COLLATE DATABASE_DEFAULT, '|', compatibility_level) FROM sys.databases WHERE name = N'cw_db';")?, "SIMPLE|SQL_Latin1_General_CP1_CS_AS|cw_owner|160")?
    expect("cw_user", q1("USE cw_db; SELECT CONCAT(SUSER_SNAME(sid) COLLATE DATABASE_DEFAULT, '|', default_schema_name COLLATE DATABASE_DEFAULT, '|', IS_ROLEMEMBER(N'db_datareader', name)) FROM sys.database_principals WHERE name = N'cw_user';")?, "cw_new_login|dbo|1")?
    expect("cw_drop_user gone", q1("USE cw_db; SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.database_principals WHERE name = N'cw_drop_user';")?, "0")?

    expect("t1 recreated with net changes", q1("USE cw_cdc; SELECT CAST(supports_net_changes AS varchar(1)) FROM cdc.change_tables WHERE capture_instance = N'dbo_t1';")?, "1")?
    expect("t2 left alone", q1("USE cw_cdc; SELECT CAST(supports_net_changes AS varchar(1)) FROM cdc.change_tables WHERE capture_instance = N'dbo_t2';")?, "1")?
    expect("t3 capture instance gone", q1("USE cw_cdc; SELECT CAST(COUNT(*) AS varchar(4)) FROM cdc.change_tables WHERE capture_instance = N'dbo_t3';")?, "0")?
    expect("cw_cdc_off CDC disabled", q1("SELECT CAST(is_cdc_enabled AS varchar(1)) FROM sys.databases WHERE name = N'cw_cdc_off';")?, "0")?

    expect("cw_job", q1("SELECT CONCAT(enabled, '|', description) FROM msdb.dbo.sysjobs WHERE name = N'cw_job';")?, "1|converged")?
    expect("cw_job steps", q1("SELECT CONCAT(COUNT(*), '|', MAX(step_name), '|', MAX(CAST(command AS nvarchar(100))), '|', MAX(database_name)) FROM msdb.dbo.sysjobsteps s JOIN msdb.dbo.sysjobs j ON j.job_id = s.job_id WHERE j.name = N'cw_job';")?, "1|Step 1|SELECT 1|master")?
    expect("cw_job schedule", q1("SELECT CONCAT(COUNT(*), '|', MAX(sc.freq_type), '|', MAX(sc.active_start_time)) FROM msdb.dbo.sysjobschedules js JOIN msdb.dbo.sysschedules sc ON sc.schedule_id = js.schedule_id JOIN msdb.dbo.sysjobs j ON j.job_id = js.job_id WHERE j.name = N'cw_job';")?, "1|4|13000")?

    expect("cw_acct", q1("SELECT CONCAT(a.email_address, '|', s.servername, '|', s.port, '|', s.enable_ssl, '|', s.username, '|', a.description) FROM msdb.dbo.sysmail_account a JOIN msdb.dbo.sysmail_server s ON s.account_id = a.account_id WHERE a.name = N'cw_acct';")?, "sql@example.com|smtp.example.com|25|0|mailer|config-weave password revision: r1")?
    expect("cw_prof linked", q1("SELECT CAST(COUNT(*) AS varchar(4)) FROM msdb.dbo.sysmail_profileaccount pa JOIN msdb.dbo.sysmail_profile p ON p.profile_id = pa.profile_id WHERE p.name = N'cw_prof';")?, "1")?
    expect("cw_drift_acct", q1("SELECT CONCAT(a.email_address, '|', s.servername, '|', s.port, '|', s.enable_ssl) FROM msdb.dbo.sysmail_account a JOIN msdb.dbo.sysmail_server s ON s.account_id = a.account_id WHERE a.name = N'cw_drift_acct';")?, "new@example.com|smtp.new.example.com|587|1")?
    expect("cw_gone profile and account", q1("SELECT CONCAT((SELECT COUNT(*) FROM msdb.dbo.sysmail_profile WHERE name = N'cw_gone_prof'), '|', (SELECT COUNT(*) FROM msdb.dbo.sysmail_account WHERE name = N'cw_gone_acct'));")?, "0|0")?

    let conf = shell::bash("grep -A3 '^\\[network\\]' /var/opt/mssql/mssql.conf | grep -c 'tcpport = 14333'", Value::Null)?
    expect("mssql.conf tcpport", conf.stdout.trim(), "1")?
    Ok(())
}
