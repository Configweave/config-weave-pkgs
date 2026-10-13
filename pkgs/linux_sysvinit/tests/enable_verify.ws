use value
use fs
use shell

fn links(name: string, kinds: string) -> Result[int, string] {
    Ok(fs::glob("/etc/rc?.d/" + kinds + "??" + name)?.len())
}

fn verify(facts: Value) -> Result[bool, string] {
    if links("cw-test", "S")? == 0 { return Err("cw-test not enabled") }

    if !fs::is_file("/etc/init.d/cw-managed") { return Err("installed init script missing") }
    if links("cw-managed", "S")? == 0 { return Err("cw-managed not enabled") }

    if fs::exists("/etc/init.d/cw-seeded") { return Err("removed init script still present") }
    if links("cw-seeded", "[SK]")? != 0 { return Err("removed service still has rc.d links") }

    // Disabled, not removed: start links gone, kill links kept.
    if links("cw-dis", "S")? != 0 { return Err("cw-dis still has start links") }
    if links("cw-dis", "K")? == 0 { return Err("cw-dis lost its kill links") }

    if links("cw-reen", "S")? == 0 { return Err("cw-reen not re-enabled") }

    if links("cw-klinks", "[SK]")? != 0 { return Err("cw-klinks still has kill links") }
    if fs::exists("/etc/init.d/cw-klinks") { return Err("cw-klinks script still present") }

    if links("cw-orphan", "[SK]")? != 0 { return Err("cw-orphan's orphaned links remain") }

    if fs::exists("/etc/init.d/cw-gone") { return Err("cw-gone script still present") }
    if links("cw-gone", "[SK]")? != 0 { return Err("cw-gone still has rc.d links") }
    let pid = fs::read("/run/cw-gone.seeded")?.trim()
    if shell::bash("kill -0 " + pid, Value::Null)?.success { return Err("cw-gone's daemon (pid " + pid + ") is still running") }
    Ok(true)
}
