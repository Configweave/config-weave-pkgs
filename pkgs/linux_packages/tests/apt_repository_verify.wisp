use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(fs::read("/etc/apt/sources.list.d/config-weave-test.list")? == "deb http://deb.debian.org/debian bookworm main\n")
}

