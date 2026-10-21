use value
use fs
use shell

fn owner(p: string) -> Result[string, string] {
    let out = shell::bash("stat -c %U " + p, Value::Null)?
    if !out.success { return Err("stat " + p + ": " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn verify(facts: Value) -> Result[bool, string] {
    let c = "/home/cwkde/.config"
    for p in [c + "/cwdir", c + "/cwdir/sub", c + "/cwdir/sub/newrc", c + "/rootrc"] {
        let o = owner(p)?
        if o != "cwkde" { return Err(p + " is owned by " + o + ", not cwkde") }
    }
    if fs::read(c + "/rootrc")? != "[X]\nk=v\n" { return Err("rootrc content changed") }
    if fs::read("/root/.config/cwdefaultrc")? != "[G]\nk=v\n" { return Err("default home entry not in /root/.config") }
    if fs::exists("/.config/cwdefaultrc") { return Err("default home resolved to /") }
    // the planted links are left alone, and so are their targets
    if fs::read_link(c + "/linkrc")? != "/root/cw-secretrc" { return Err("linkrc is no longer the planted symlink") }
    if fs::read_link(c + "/danglerc")? != "/root/cw-nowhere" { return Err("danglerc is no longer the planted symlink") }
    if fs::read("/root/cw-secretrc")? != "[S]\nsecret=1\n" { return Err("the symlink target was changed") }
    if owner("/root/cw-secretrc")? != "root" { return Err("the symlink target was handed to cwkde") }
    if fs::lexists("/root/cw-nowhere") { return Err("a file was created at the dangling symlink's target") }
    Ok(true)
}
