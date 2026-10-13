use value
use fs
use shell

fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("pacman -Q " + name + " >/dev/null 2>&1", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    if !installed("cw-leaf")? { return Err("cw-leaf should be installed") }
    if installed("cw-rm")? { return Err("cw-rm should be removed") }
    if installed("cw-prov")? { return Err("cw-prov needed a user and should not be installed") }
    if !fs::is_file("/var/lib/config-weave/pacman-aur-cache-updated") { return Err("aur_cache_updated left no stamp") }
    // every helper run was as cwbuild, with its own HOME, from its home
    let log = fs::read("/tmp/cw-yay.log")?.trim()
    if log == "" { return Err("the helper never ran") }
    for l in log.split("\n") {
        if l != "user=cwbuild home=/home/cwbuild pwd=/home/cwbuild" { return Err("helper ran as: " + l) }
    }
    Ok(true)
}
