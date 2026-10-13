use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(
        fs::read("/etc/apt/keyrings/cw-test.asc")?.contains("PGP PUBLIC KEY BLOCK") &&
        !fs::exists("/etc/apt/keyrings/cw-stale.asc")
    )
}
