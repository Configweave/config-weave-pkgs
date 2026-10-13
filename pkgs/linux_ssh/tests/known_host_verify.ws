use value
use fs
use shell

fn stat(p: string) -> Result[string, string] {
    let out = shell::bash("stat -c '%a %U %G' -- '" + p + "'", Value::Null)?
    if !out.success { return Err("stat " + p + " failed") }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    let root = fs::read("/root/.ssh/known_hosts")?
    let want = "cw-rot.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINewRotatedHostKey\ncw-rot.example ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABOtherTypeKey\ncw-default.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDefaultHomeKey\n"
    if root != want { return Err("root known_hosts is\n" + root) }
    if fs::exists("/.ssh/known_hosts") { return Err("an entry was written under HOME=/") }
    if stat("/root/.ssh")? != "700 root root" { return Err("/root/.ssh is " + stat("/root/.ssh")?) }

    let user = fs::read("/home/cwkh/.ssh/known_hosts")?
    if user != "cw-user.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIUserHomeHostKey\n" { return Err("cwkh known_hosts is\n" + user) }
    if stat("/home/cwkh/.ssh")? != "700 cwkh users" { return Err("/home/cwkh/.ssh is " + stat("/home/cwkh/.ssh")?) }
    if !stat("/home/cwkh/.ssh/known_hosts")?.ends_with(" cwkh users") { return Err("cwkh known_hosts is " + stat("/home/cwkh/.ssh/known_hosts")?) }

    if fs::read("/etc/ssh/ssh_known_hosts")? != "@cert-authority *.cw.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAICertAuthorityKey\n" { return Err("ssh_known_hosts not written") }
    Ok(true)
}
