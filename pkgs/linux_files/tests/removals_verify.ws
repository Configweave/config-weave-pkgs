use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    if fs::exists("/tmp/cw-del.txt") { return Err("cw-del.txt still exists") }
    if fs::exists("/tmp/cw-rmdir") { return Err("cw-rmdir still exists") }
    if fs::read_link("/tmp/cw-oldlink").is_ok() { return Err("cw-oldlink still exists") }
    if fs::read_link("/tmp/cw-dangling-rm").is_ok() { return Err("dangling link still exists") }
    if fs::exists("/tmp/cw-hard-link.txt") { return Err("hard link still exists") }
    // removing one name of a hard link must not touch the other
    if fs::read("/tmp/cw-hard-src.txt")? != "keep\n" { return Err("hard link source lost its content") }
    if !fs::is_file("/tmp/cw-extracted/inside.txt") { return Err("archive not extracted") }
    Ok(true)
}
