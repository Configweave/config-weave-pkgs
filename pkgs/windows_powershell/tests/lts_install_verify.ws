use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    // The LTS package, not the stable one, and its own binary and root.
    let pkg = shell::run("dpkg-query -W -f=${{Version}} powershell-lts", Value::Null)?
    if !pkg.success { return Err("the powershell-lts package is not installed: " + pkg.stderr.trim()) }
    let stable = shell::run("dpkg-query -W -f=${{Status}} powershell", Value::Null)?
    if stable.success && stable.stdout.contains("installed") { return Err("channel = :lts installed the stable powershell package") }
    if !fs::is_file("/opt/microsoft/powershell/7-lts/pwsh") { return Err("the LTS root /opt/microsoft/powershell/7-lts was not created") }
    let out = shell::run("pwsh-lts -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if !out.success { return Err("pwsh-lts does not run: " + out.stderr.trim()) }
    // The deb version is <version>-1.deb.
    if !pkg.stdout.starts_with(out.stdout.trim() + "-") { return Err("pwsh-lts reports " + out.stdout.trim() + " but the package is " + pkg.stdout) }
    Ok(true)
}
