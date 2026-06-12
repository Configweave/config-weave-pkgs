use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let text = fs::read("/tmp/cw-files/a.txt")?
    let lines = fs::read("/tmp/cw-files/lines.txt")?
    Ok(text == "alpha\n" && lines.contains("beta") && fs::read_link("/tmp/cw-files/link.txt")? == "/tmp/cw-files/a.txt")
}
