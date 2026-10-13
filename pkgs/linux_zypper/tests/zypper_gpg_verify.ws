use value
use fs
use shell

fn imported(id: string) -> Result[bool, string] {
    Ok(shell::bash("rpm -q gpg-pubkey-" + id + " >/dev/null 2>&1", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    let d = "/etc/pki/rpm-gpg/"
    if !imported("65aa662b-6acdeb34")? { return Err("cw-reimport's key should be in the rpm database") }
    if !fs::is_file(d + "cw-reimport.asc") { return Err("cw-reimport.asc should exist") }
    if imported("9f64a8a0-6acdeb34")? { return Err("cw-gone's key should be gone from the rpm database") }
    if fs::exists(d + "cw-gone.asc") || fs::exists(d + "cw-stale.asc") { return Err("cw-gone.asc and cw-stale.asc should be deleted") }
    if fs::exists(d + "cw-bad.asc") || fs::exists(d + ".cw-bad.asc.cw-tmp") { return Err("an invalid key left a file behind") }
    Ok(true)
}
