use value
use common
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let want = common::latest_release("lts", "")?
    let pkg = shell::run("dpkg-query -W -f=${{Version}} powershell-lts", Value::Null)?
    if pkg.stdout.trim() != want + "-1.deb" { return Err("powershell-lts is " + pkg.stdout.trim() + ", not the latest LTS " + want) }
    let out = shell::run("pwsh-lts -NoProfile -NonInteractive -Command $PSVersionTable.PSVersion.ToString()", Value::Null)?
    if out.stdout.trim() != want { return Err("pwsh-lts reports " + out.stdout.trim() + ", not " + want) }
    Ok(true)
}
