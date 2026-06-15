use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let sources = fs::read("/etc/apt/sources.list.d/cw-modern.sources")?
    let key = fs::read("/etc/apt/keyrings/cw-test.asc")?
    Ok(sources.contains("Suites: bookworm") && key.contains("PGP PUBLIC KEY"))
}
