use value
use fs
use shell
use hash

fn verify(facts: Value) -> Result[bool, string] {
    if fs::exists("/tmp/cw-del.txt") { return Err("cw-del.txt still exists") }
    if fs::exists("/tmp/cw-rmdir") { return Err("cw-rmdir still exists") }
    if !fs::is_dir("/srv") || !fs::is_dir("/usr/bin") { return Err("a refused removal deleted a top-level directory") }
    if fs::read_link("/tmp/cw-oldlink").is_ok() { return Err("cw-oldlink still exists") }
    if fs::read_link("/tmp/cw-dangling-rm").is_ok() { return Err("dangling link still exists") }
    if fs::exists("/tmp/cw-hard-link.txt") { return Err("hard link still exists") }
    // removing one name of a hard link must not touch the other
    if fs::read("/tmp/cw-hard-src.txt")? != "keep\n" { return Err("hard link source lost its content") }
    if !fs::is_file("/tmp/cw-extracted/inside.txt") { return Err("archive not extracted") }
    // owner, group and modes reach every entry, the marker included
    let bad = shell::bash("find /tmp/cw-extracted \\( ! -user 1234 -o ! -group 1234 -o \\( -type f ! -perm 0640 \\) -o \\( -type d ! -perm 0750 \\) \\) -print", Value::Null)?
    if !bad.success || bad.stdout.trim() != "" { return Err("extracted tree attrs not converged: " + bad.stdout.trim() + bad.stderr.trim()) }
    if !fs::is_file("/tmp/cw-extracted/sub/deep.txt") { return Err("nested entry not extracted") }
    if fs::read("/tmp/cw-prepop/inside.txt")? != "hi\n" { return Err("pre-populated dest was not extracted into") }
    if fs::read("/tmp/cw-prepop/existing.txt")? != "mine\n" { return Err("extraction removed an unrelated file") }
    if fs::read("/tmp/cw-changed/inside.txt")? != "hi\n" { return Err("changed src was not re-extracted") }
    if fs::read("/tmp/cw-changed/.config-weave-archive")?.trim() != hash::sha256_file("/tmp/cw-arch.tar.gz")? { return Err("marker does not hold the archive digest") }
    if fs::exists("/tmp/cw-arch-rm") { return Err("extracted tree was not removed") }
    if !fs::is_dir("/opt") { return Err("a refused removal deleted /opt") }
    Ok(true)
}
