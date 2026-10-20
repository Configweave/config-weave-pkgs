use value
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let pkg = shell::run("dpkg-query -W -f=${{Version}} powershell-preview", Value::Null)?
    if pkg.stdout.trim() != "7.7.0-preview.5-1.deb" { return Err("powershell-preview is '" + pkg.stdout.trim() + "', not 7.7.0-preview.5-1.deb") }
    let out = shell::run("pwsh-preview -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if out.stdout.trim() != "7.7.0-preview.5" { return Err("pwsh-preview reports " + out.stdout.trim()) }
    Ok(true)
}
