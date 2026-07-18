use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(
        fs::read("/etc/apt/sources.list.d/config-weave-test.list")? == "deb http://deb.debian.org/debian bookworm main\n" &&
        !fs::exists("/etc/apt/sources.list.d/cw-stale.list") &&
        fs::read("/etc/apt/keyrings/cw-test.asc")?.contains("PGP PUBLIC KEY BLOCK") &&
        !fs::exists("/etc/apt/keyrings/cw-stale.asc")
    )
}
