use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    Ok(
        !fs::exists("/tmp/cw-del.txt") &&
        !fs::exists("/tmp/cw-rmdir") &&
        fs::read_link("/tmp/cw-oldlink").is_err() &&
        fs::is_file("/tmp/cw-extracted/inside.txt")
    )
}
