use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(fs::read("/root/.ssh/known_hosts")?.contains("cw-test.example ssh-ed25519"))
}
