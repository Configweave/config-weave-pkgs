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
    expect("collation", q1("SELECT CAST(SERVERPROPERTY('Collation') AS nvarchar(128));")?, "Latin1_General_CI_AS")?
    expect("major version", q1("SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS nvarchar(8));")?, "17")?
    let svc = shell::bash("systemctl is-enabled mssql-server", Value::Null)?
    expect("mssql-server enabled", svc.stdout.trim(), "enabled")?
    Ok(())
}
