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
    let gen = fs::read("/etc/locale.gen")?
    if !gen.contains("en_AU.UTF-8 UTF-8") { return Err("locale not enabled in /etc/locale.gen") }
    let de_gone = !gen.contains("\nde_DE.UTF-8 UTF-8") && !gen.starts_with("de_DE.UTF-8 UTF-8")
    if !de_gone { return Err("seeded locale still enabled in /etc/locale.gen") }
    if !has_fstab_line("tmpfs /mnt/cw-test tmpfs defaults 0 0")? { return Err("fstab entry missing") }
    Ok(true)
}
