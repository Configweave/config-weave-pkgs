use value
use fs
use shell

// Shared by line_edits_converge (/tmp/cw-line) and line_invalid_input
// (/tmp/cw-line-bad). Each test checks the tree its setup seeded; the two
// may share a container in group "files", so both are checked when present.

fn stat(p: string) -> Result[string, string] {
    let out = shell::bash("stat -c '%a %u %g' -- '" + p + "'", Value::Null)?
    if !out.success { return Err("stat " + p + ": " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn expect(what: string, got: string, want: string) -> Result[unit, string] {
    if got != want { return Err(what + ": expected '" + want + "', got '" + got + "'") }
    Ok(())
}

fn verify_edits() -> Result[unit, string] {
    let d = "/tmp/cw-line/"
    expect("dup.conf", fs::read(d + "dup.conf")?, "a\nkeep=1\nab\n")?
    expect("append.conf", fs::read(d + "append.conf")?, "x\ny\nz\n")?
    expect("append.conf attrs", stat(d + "append.conf")?, "640 65534 65534")?
    expect("exact.conf", fs::read(d + "exact.conf")?, "one\ntwo\n")?
    expect("nonl.conf", fs::read(d + "nonl.conf")?, "only")?
    expect("rm.conf", fs::read(d + "rm.conf")?, "q\n p\np \n")?
    expect("rm_none.conf", fs::read(d + "rm_none.conf")?, "q\n")?
    expect("last.conf", fs::read(d + "last.conf")?, "")?
    if fs::lexists(d + "missing.conf") { return Err("absent created missing.conf") }
    expect("new/created.conf", fs::read(d + "new/created.conf")?, "hello\n")?
    if fs::lexists(d + "nocreate.conf") { return Err("create = false created nocreate.conf") }
    expect("link.conf target", fs::read_link(d + "link.conf")?, "/tmp/cw-line/real.conf")?
    expect("real.conf", fs::read(d + "real.conf")?, "r\ns\n")?
    expect("real.conf attrs", stat(d + "real.conf")?, "600 65534 65534")?
    if !fs::glob("/tmp/cw-line/.*.cw-tmp")?.is_empty() { return Err("a temp file was left behind") }
    Ok(())
}

fn verify_invalid() -> Result[unit, string] {
    let d = "/tmp/cw-line-bad/"
    expect("keep.conf", fs::read(d + "keep.conf")?, "k\n")?
    let bin = shell::bash("[ \"$(od -An -tx1 /tmp/cw-line-bad/binary.conf | tr -d ' \\n')\" = fffe0a ]", Value::Null)?
    if !bin.success { return Err("binary.conf was rewritten") }
    if fs::lexists("/tmp/cw-line-bad/rel.conf") || fs::lexists("/tmp/cw-line-escape.conf") { return Err("a rejected path was written") }
    if !fs::glob("/tmp/cw-line-bad/.*.cw-tmp")?.is_empty() { return Err("a temp file was left behind") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    let edits = fs::is_dir("/tmp/cw-line")
    let invalid = fs::is_dir("/tmp/cw-line-bad")
    if !edits && !invalid { return Err("neither /tmp/cw-line nor /tmp/cw-line-bad exists") }
    if edits { verify_edits()? }
    if invalid { verify_invalid()? }
    Ok(true)
}
