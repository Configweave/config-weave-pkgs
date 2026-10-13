use value
use shell

fn installed(name: string) -> Result[bool, string] {
    Ok(shell::bash("pacman -Q " + name + " >/dev/null 2>&1", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    if !installed("cw-leaf")? { return Err("cw-leaf should be installed") }
    if !installed("cw-g2a")? || !installed("cw-g2b")? { return Err("both members of cw-group2 should be installed") }
    if installed("cw-rm")? { return Err("cw-rm should be removed") }
    if installed("cw-prov")? { return Err("cw-prov, which provides cw-virt2, should be removed") }
    // the guarded removal changed nothing
    if !installed("cw-base")? || !installed("cw-dep")? { return Err("cw-base and cw-dep should both still be installed") }
    Ok(true)
}
