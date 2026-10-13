use value
use fs
use shell

fn imported(id: string) -> Result[bool, string] {
    Ok(shell::bash("rpm -q gpg-pubkey-" + id + " >/dev/null 2>&1", Value::Null)?.success)
}

fn verify(facts: Value) -> Result[bool, string] {
    let d = "/etc/pki/rpm-gpg/"
    if !imported("74bfbe19618aafbe09ea3cadd3c3eead65aa662b-6acdeb34")? { return Err("cw-reimport's key should be in the rpm database") }
    if !fs::is_file(d + "cw-reimport.asc") { return Err("cw-reimport.asc should exist") }
    if imported("1d58e9589ad27b04392bf7ef2568ca9a9f64a8a0-6acdeb34")? { return Err("cw-gone's key should be gone from the rpm database") }
    if fs::exists(d + "cw-gone.asc") || fs::exists(d + "cw-stale.asc") { return Err("cw-gone.asc and cw-stale.asc should be deleted") }
    if fs::exists(d + "cw-bad.asc") || fs::exists(d + ".cw-bad.asc.cw-tmp") { return Err("an invalid key left a file behind") }
    if fs::exists("/etc/pki/cw-evil.asc") { return Err("a traversal name wrote outside /etc/pki/rpm-gpg") }
    Ok(true)
}
