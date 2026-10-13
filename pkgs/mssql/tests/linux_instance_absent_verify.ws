use value
use fs
use shell

// The package is gone, so is the engine binary.
fn verify(facts: Value) -> Result[bool, string] {
    let out = shell::bash("dpkg-query -W -f='${{Status}}' mssql-server 2>/dev/null | grep -c '^install ok installed'", Value::Null)?
    if out.stdout.trim() != "0" {
        return Err("mssql-server is still installed")
    }
    if fs::exists("/opt/mssql/bin/sqlservr") {
        return Err("/opt/mssql/bin/sqlservr is still there")
    }
    Ok(true)
}
