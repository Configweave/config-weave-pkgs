use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let target = fs::read_link("/etc/localtime")?
    if target != "/usr/share/zoneinfo/Australia/Brisbane" { return Err("/etc/localtime points at " + target) }
    if fs::read("/etc/timezone")? != "Australia/Brisbane\n" { return Err("/etc/timezone not converged") }
    Ok(true)
}
