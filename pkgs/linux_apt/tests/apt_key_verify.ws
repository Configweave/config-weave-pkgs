use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let d = "/etc/apt/keyrings/"
    if !fs::read(d + "cw-plain.asc")?.contains("PGP PUBLIC KEY BLOCK") { return Err("cw-plain.asc not written") }
    if fs::exists(d + "cw-plain.gpg") { return Err("dearmor defaults to false, but cw-plain.gpg was made") }
    // gpg itself reads the rebuilt keyring as the test key
    let k = shell::bash("gpg --batch --show-keys " + d + "cw-dearmor.gpg", Value::Null)?
    if !k.success || !k.stdout.contains("74BFBE19618AAFBE09EA3CADD3C3EEAD65AA662B") { return Err("cw-dearmor.gpg is not the dearmored key: " + k.stderr.trim()) }
    if fs::exists(d + "cw-stale.asc") || fs::exists(d + "cw-stale.gpg") { return Err("cw-stale should be gone, .asc and .gpg") }
    if fs::exists("/etc/apt/trusted.gpg.d/cw-evil.asc") { return Err("a traversal name wrote into trusted.gpg.d") }
    Ok(true)
}
