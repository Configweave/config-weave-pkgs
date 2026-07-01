use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    if !fs::is_dir("/srv/checkout/.git") { return Err("checkout has no .git directory") }
    Ok(fs::read("/srv/checkout/README.md")? == "hello\n")
}
