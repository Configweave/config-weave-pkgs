use value
use fs
use shell

fn stat(p: string) -> Result[string, string] {
    let out = shell::bash("stat -c '%a %u %g' -- '" + p + "'", Value::Null)?
    if !out.success { return Err("stat " + p + ": " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn expect(what: string, got: string, want: string) -> Result[unit, string] {
    if got != want { return Err(what + ": expected '" + want + "', got '" + got + "'") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    expect("a.txt content", fs::read("/tmp/cw-files/a.txt")?, "alpha\n")?
    expect("a.txt attrs", stat("/tmp/cw-files/a.txt")?, "644 0 0")?
    expect("dir attrs", stat("/tmp/cw-files")?, "755 0 0")?
    expect("binary.txt content", fs::read("/tmp/cw-files/binary.txt")?, "text\n")?
    expect("keep.txt content", fs::read("/tmp/cw-files/keep.txt")?, "new\n")?
    expect("keep.txt attrs", stat("/tmp/cw-files/keep.txt")?, "604 65534 65534")?
    expect("link.txt target", fs::read_link("/tmp/cw-files/link.txt")?, "/tmp/cw-files/a.txt")?
    let hard = shell::bash("[ \"$(stat -c '%d:%i' /tmp/cw-files/hard.txt)\" = \"$(stat -c '%d:%i' /tmp/cw-files/a.txt)\" ]", Value::Null)?
    if !hard.success { return Err("hard.txt is not a hard link to a.txt") }
    if !fs::glob("/tmp/cw-files/.*.cw-tmp")?.is_empty() { return Err("a temp file was left behind") }
    Ok(true)
}
