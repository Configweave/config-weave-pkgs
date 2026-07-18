use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(fs::read("/etc/hosts")?.contains("192.0.2.10 cw-test.local cw-test"))
}
