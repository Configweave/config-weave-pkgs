use value
use fs

fn has_fstab_line(line: string) -> Result[bool, string] {
    for l in fs::read("/etc/fstab")?.split("\n") {
        if l.trim() == line { return Ok(true) }
    }
    Ok(false)
}

fn verify(facts: Value) -> Result[bool, string] {
    if fs::read("/etc/hostname")? != "cw-test-host\n" { return Err("/etc/hostname not converged") }
    if fs::read("/etc/timezone")?.trim() != "Australia/Brisbane" { return Err("/etc/timezone not converged") }
    if fs::read("/etc/locale.conf")? != "LANG=C.UTF-8\n" { return Err("/etc/locale.conf not converged") }
    if !has_fstab_line("tmpfs /mnt/cw-test tmpfs defaults 0 0")? { return Err("fstab entry missing") }
    Ok(true)
}
