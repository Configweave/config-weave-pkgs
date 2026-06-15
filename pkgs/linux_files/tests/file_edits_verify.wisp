use value
use fs

fn verify(facts: Value) -> Result[bool, string] {
    let block = fs::read("/tmp/cw-block.txt")?
    let subst = fs::read("/tmp/cw-subst.txt")?
    let seed = fs::read("/tmp/cw-seed.txt")?
    Ok(
        block.contains("# BEGIN config-weave") && block.contains("hello") &&
        subst.contains("replaced") && !subst.contains("replace-me") &&
        seed.contains("one") && seed.contains("three") && !seed.contains("two") &&
        !fs::exists("/tmp/cw-del.txt") &&
        fs::is_file("/tmp/cw-extracted/inside.txt")
    )
}
