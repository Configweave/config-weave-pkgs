use value
use fs
use shell

fn stat(p: string) -> Result[string, string] {
    let out = shell::bash("stat -c '%a %U %G' -- '" + p + "'", Value::Null)?
    if !out.success { return Err("stat " + p + " failed") }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    let root = fs::read("/root/.ssh/authorized_keys")?
    let want = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIRotateCommentKey new-comment\nssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIKeepThisKeyUntouched keep\n"
    if root != want { return Err("root authorized_keys is\n" + root) }
    if stat("/root/.ssh")? != "700 root root" { return Err("/root/.ssh is " + stat("/root/.ssh")?) }
    if stat("/root/.ssh/authorized_keys")? != "600 root root" { return Err("root authorized_keys is " + stat("/root/.ssh/authorized_keys")?) }

    let user = fs::read("/home/cwkey/.ssh/authorized_keys")?
    if user != "restrict ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINonRootUserKey cwkey@test\n" { return Err("cwkey authorized_keys is\n" + user) }
    if stat("/home/cwkey/.ssh")? != "700 cwkey users" { return Err("/home/cwkey/.ssh is " + stat("/home/cwkey/.ssh")?) }
    if stat("/home/cwkey/.ssh/authorized_keys")? != "600 cwkey users" { return Err("cwkey authorized_keys is " + stat("/home/cwkey/.ssh/authorized_keys")?) }
    if fs::exists("/root/.ssh/.authorized_keys.cw-tmp") { return Err("temp file left behind") }

    // the planted links are left alone, and so are their targets
    if fs::read_link("/home/cwlink/.ssh/authorized_keys")? != "/root/cw-secret-keys" { return Err("cwlink authorized_keys is no longer the planted symlink") }
    if fs::read_link("/home/cwdangle/.ssh/authorized_keys")? != "/root/cw-nowhere-keys" { return Err("cwdangle authorized_keys is no longer the planted symlink") }
    if stat("/root/cw-secret-keys")? != "600 root root" { return Err("the symlink target is now " + stat("/root/cw-secret-keys")?) }
    if fs::read("/root/cw-secret-keys")? != "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlantedLinkSecretKey root\n" { return Err("the symlink target was changed") }
    if fs::lexists("/root/cw-nowhere-keys") { return Err("a file was created at the dangling symlink's target") }
    if fs::lexists("/home/cwlink/.ssh/.authorized_keys.cw-tmp") { return Err("temp file left behind for cwlink") }
    Ok(true)
}
