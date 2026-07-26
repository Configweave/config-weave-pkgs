use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(!fs::glob("/etc/rc?.d/S??cw-test")?.is_empty())
}
