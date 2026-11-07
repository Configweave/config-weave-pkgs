use value
use fs
use shell

// Shared by blocks_converge (/tmp/cw-block) and block_invalid_input
// (/tmp/cw-block-bad). Each test checks the tree its setup seeded; the two
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

fn verify_blocks() -> Result[unit, string] {
    let d = "/tmp/cw-block/"
    expect("append.conf", fs::read(d + "append.conf")?, "x\ny\n# BEGIN config-weave\nb1\nb2\n# END config-weave\n")?
    expect("append.conf attrs", stat(d + "append.conf")?, "640 65534 65534")?
    expect("replace.conf", fs::read(d + "replace.conf")?, "head \t\n# BEGIN config-weave\nnew1\nnew2\n# END config-weave\n# BEGIN other\nkeep\n# END other\n# BEGIN config-weave \ntail\n")?
    expect("exact.conf", fs::read(d + "exact.conf")?, "a\n# BEGIN config-weave\nsame\n# END config-weave")?
    expect("label.conf", fs::read(d + "label.conf")?, "# BEGIN config-weave\nx\n# END config-weave\n# BEGIN app\ny\n# END app\n")?
    expect("multi.conf", fs::read(d + "multi.conf")?, "base\n# BEGIN a\n1\n# END a\n# BEGIN b\n2\n# END b\n")?
    expect("remove.conf", fs::read(d + "remove.conf")?, "a\nb\n")?
    expect("remove_other.conf", fs::read(d + "remove_other.conf")?, "# BEGIN other\nk\n# END other\n")?
    expect("remove_whole.conf", fs::read(d + "remove_whole.conf")?, "")?
    if fs::lexists(d + "missing.conf") { return Err("absent created missing.conf") }
    expect("new/created.conf", fs::read(d + "new/created.conf")?, "# BEGIN config-weave\nhello\n# END config-weave\n")?
    if fs::lexists(d + "nocreate.conf") { return Err("create = false created nocreate.conf") }
    expect("link.conf target", fs::read_link(d + "link.conf")?, "/tmp/cw-block/real.conf")?
    expect("real.conf", fs::read(d + "real.conf")?, "r\n# BEGIN config-weave\ns\n# END config-weave\n")?
    expect("real.conf attrs", stat(d + "real.conf")?, "600 65534 65534")?
    if !fs::glob("/tmp/cw-block/.*.cw-tmp")?.is_empty() { return Err("a temp file was left behind") }
    Ok(())
}

fn verify_invalid() -> Result[unit, string] {
    let d = "/tmp/cw-block-bad/"
    expect("keep.conf", fs::read(d + "keep.conf")?, "k\n")?
    expect("begin_only.conf", fs::read(d + "begin_only.conf")?, "# BEGIN config-weave\nx\n")?
    expect("end_only.conf", fs::read(d + "end_only.conf")?, "x\n# END config-weave\n")?
    expect("reversed.conf", fs::read(d + "reversed.conf")?, "# END config-weave\n# BEGIN config-weave\n")?
    expect("nested.conf", fs::read(d + "nested.conf")?, "# BEGIN config-weave\n# BEGIN config-weave\nx\n# END config-weave\n# END config-weave\n")?
    expect("duplicate.conf", fs::read(d + "duplicate.conf")?, "# BEGIN config-weave\na\n# END config-weave\n# BEGIN config-weave\nb\n# END config-weave\n")?
    let bin = shell::bash("[ \"$(od -An -tx1 /tmp/cw-block-bad/binary.conf | tr -d ' \\n')\" = fffe0a ]", Value::Null)?
    if !bin.success { return Err("binary.conf was rewritten") }
    if fs::lexists("/tmp/cw-block-bad/rel.conf") || fs::lexists("/tmp/cw-block-escape.conf") { return Err("a rejected path was written") }
    if !fs::glob("/tmp/cw-block-bad/.*.cw-tmp")?.is_empty() { return Err("a temp file was left behind") }
    Ok(())
}

fn verify(facts: Value) -> Result[bool, string] {
    let blocks = fs::is_dir("/tmp/cw-block")
    let invalid = fs::is_dir("/tmp/cw-block-bad")
    if !blocks && !invalid { return Err("neither /tmp/cw-block nor /tmp/cw-block-bad exists") }
    if blocks { verify_blocks()? }
    if invalid { verify_invalid()? }
    Ok(true)
}
