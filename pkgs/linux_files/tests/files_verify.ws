use value
use fs
use shell

fn verify(facts: Value) -> Result[bool, string] {
    let text = fs::read("/tmp/cw-files/a.txt")?
    let hard = shell::bash("[ \"$(stat -c '%d:%i' /tmp/cw-files/hard.txt)\" = \"$(stat -c '%d:%i' /tmp/cw-files/a.txt)\" ]", Value::Null)?
    Ok(text == "alpha\n" &&
       fs::read_link("/tmp/cw-files/link.txt")? == "/tmp/cw-files/a.txt" &&
       hard.success)
}
