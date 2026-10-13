use value
use fs

fn links(name: string, kinds: string) -> Result[int, string] {
    Ok(fs::glob("/etc/rc?.d/" + kinds + "??" + name)?.len())
}

fn verify(facts: Value) -> Result[bool, string] {
    if links("cw-ck", "S")? == 0 { return Err("cw-ck not enabled") }

    if links("cw-ckdis", "S")? != 0 { return Err("cw-ckdis still has start links") }
    if links("cw-ckdis", "K")? == 0 { return Err("cw-ckdis lost its kill links") }

    if fs::exists("/etc/init.d/cw-ckgone") { return Err("cw-ckgone script still present") }
    if links("cw-ckgone", "[SK]")? != 0 { return Err("cw-ckgone still has rc.d links") }
    Ok(true)
}
