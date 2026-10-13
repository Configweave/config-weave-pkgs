use value
use shell

fn debconf(cmd: string) -> Result[string, string] {
    let out = shell::bash("printf '" + cmd + "\\n' | DEBIAN_FRONTEND=noninteractive debconf-communicate cw-test", Value::Null)?
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    let tz = shell::bash("test \"$(dpkg-query -W -f='${{db:Status-Status}}' tzdata 2>/dev/null)\" = installed", Value::Null)?
    if tz.success { return Err("tzdata should have been removed") }
    let holds = shell::bash("apt-mark showhold", Value::Null)?
    if !holds.success { return Err(holds.stderr.trim()) }
    let held = holds.stdout
    if !held.contains("base-files") { return Err("base-files should be held") }
    if held.contains("gzip") { return Err("gzip should have been unheld") }
    if debconf("GET cw-test/enable")? != "0 true" { return Err("debconf answer not set") }
    if debconf("METAGET cw-test/typed type")? != "0 boolean" { return Err("cw-test/typed should now be a boolean") }
    if debconf("GET cw-test/secret")? != "0 it's a s3cret; $HOME" { return Err("the password answer did not arrive intact") }
    if debconf("METAGET cw-test/secret type")? != "0 password" { return Err("cw-test/secret should be a password") }
    if !debconf("GET cw-test/gone")?.starts_with("10 ") { return Err("cw-test/gone should no longer exist") }
    Ok(true)
}
