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
    expect("cw_ag", q1("SELECT CONCAT(ag.cluster_type_desc COLLATE DATABASE_DEFAULT, '|', r.endpoint_url COLLATE DATABASE_DEFAULT) FROM sys.availability_groups ag JOIN sys.availability_replicas r ON r.group_id = ag.group_id WHERE ag.name = N'cw_ag';")?,
        "none|TCP://" + q1("SELECT CAST(SERVERPROPERTY('MachineName') AS nvarchar(128));")? + ":5022")?
    expect("endpoint port", q1("SELECT CAST(port AS varchar(8)) FROM sys.tcp_endpoints WHERE name = N'Hadr_endpoint';")?, "5022")?
    expect("cw_ag_off gone", q1("SELECT CAST(COUNT(*) AS varchar(4)) FROM sys.availability_groups WHERE name = N'cw_ag_off';")?, "0")?
    Ok(())
}
