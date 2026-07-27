use value
use fs

fn enabled(name: string) -> Result[bool, string] {
    Ok(!fs::glob("/etc/rc?.d/S??" + name)?.is_empty())
}

fn verify(facts: Value) -> Result[bool, string] {
    if !enabled("cw-test")? { return Err("cw-test not enabled") }

    if !fs::is_file("/etc/init.d/cw-managed") { return Err("installed init script missing") }
    if !enabled("cw-managed")? { return Err("cw-managed not enabled") }

    if fs::exists("/etc/init.d/cw-seeded") { return Err("removed init script still present") }
    if enabled("cw-seeded")? { return Err("removed service still has rc.d start links") }
    Ok(true)
}
