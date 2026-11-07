use value
use fs
use shell

// Shared by substitution_converges (/tmp/cw-sub) and
// substitution_invalid_input (/tmp/cw-sub-bad). Each test checks the tree
// its setup seeded; the two may share a container in group
// "files-substitution", so both are checked when present.

fn stat(p: string) -> Result[string, string] {
    let out = shell::bash("stat -c '%a %u %g' -- '" + p + "'", Value::Null)?
    if !out.success { return Err("stat " + p + ": " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn expect(what: string, got: string, want: string) -> Result[unit, string] {
    if got != want { return Err(what + ": expected '" + want + "', got '" + got + "'") }
    Ok(())
}

fn verify_converges() -> Result[unit, string] {
    let d = "/tmp/cw-sub/"
    expect("captures.conf", fs::read(d + "captures.conf")?, "# head\na=1\nb=2\nc=3\n")?
    expect("named.conf", fs::read(d + "named.conf")?, "mail user@new.example\nadmin@new.example\n")?
    expect("delete.conf", fs::read(d + "delete.conf")?, "keep\nplain\nline\n")?
    expect("multiline.conf", fs::read(d + "multiline.conf")?, "a\nBLOCK\nb\n")?
    expect("nonl.conf", fs::read(d + "nonl.conf")?, "x=new")?
    expect("attrs.conf", fs::read(d + "attrs.conf")?, "level=info\n")?
    expect("attrs.conf attrs", stat(d + "attrs.conf")?, "640 65534 65534")?
    expect("link.conf target", fs::read_link(d + "link.conf")?, "/tmp/cw-sub/real.conf")?
    expect("real.conf", fs::read(d + "real.conf")?, "level=info\n")?
    expect("real.conf attrs", stat(d + "real.conf")?, "600 65534 65534")?
    expect("nomatch.conf", fs::read(d + "nomatch.conf")?, "nothing here\n")?
    expect("done.conf", fs::read(d + "done.conf")?, "a=1\nb=2\n")?
    if !fs::glob("/tmp/cw-sub/.*.cw-tmp")?.is_empty() { return Err("a temp file was left behind") }
    Ok(())
}

fn verify_invalid() -> Result[unit, string] {
    let d = "/tmp/cw-sub-bad/"
    expect("grow.conf", fs::read(d + "grow.conf")?, "a\n")?
    expect("empty_match.conf", fs::read(d + "empty_match.conf")?, "abc\n")?
    expect("link.conf target", fs::read_link(d + "link.conf")?, "/tmp/cw-sub-bad/real.conf")?
    expect("real.conf", fs::read(d + "real.conf")?, "a\n")?
    expect("real.conf mode", stat(d + "real.conf")?.split(" ").get(0).unwrap_or(""), "600")?
    expect("keep.conf", fs::read(d + "keep.conf")?, "k\n")?
    let bin = shell::bash("[ \"$(od -An -tx1 /tmp/cw-sub-bad/binary.conf | tr -d ' \\n')\" = fffe0a ]", Value::Null)?
    if !bin.success { return Err("binary.conf was rewritten") }
    if fs::lexists(d + "missing.conf") { return Err("a missing path was created") }
    if !fs::glob("/tmp/cw-sub-bad/.*.cw-tmp")?.is_empty() { return Err("a temp file was left behind") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    let converges = fs::is_dir("/tmp/cw-sub")
    let invalid = fs::is_dir("/tmp/cw-sub-bad")
    if !converges && !invalid { return Err("neither /tmp/cw-sub nor /tmp/cw-sub-bad exists") }
    if converges { verify_converges()? }
    if invalid { verify_invalid()? }
    Ok(true)
}
