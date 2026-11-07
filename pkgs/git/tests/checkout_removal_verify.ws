use value
use fs

// checkout_removal: the two removals happened, and every refused path is
// still there with its content.
fn gone(p: string) -> Result[bool, string] {
    if fs::lexists(p) { return Err(p + " should have been removed") }
    Ok(true)
}

fn kept(p: string) -> Result[bool, string] {
    if !fs::lexists(p) { return Err(p + " should still exist") }
    Ok(true)
}

fn verify(facts: Value) -> Result[bool, string] {
    let b = "/srv/cw-co/removal"

    let removed = gone(b + "/clean")? && gone(b + "/forced")? && gone(b + "/never")?

    let refused = kept(b + "/dirty/untracked.txt")? &&
        kept(b + "/wrongorigin/.git")? &&
        kept(b + "/foreign/keep.txt")? &&
        kept(b + "/empty")? &&
        kept(b + "/nested/sub/s.txt")? &&
        kept(b + "/nested/.git")? &&
        kept(b + "/target/.git")? &&
        kept("/srv")?
    if fs::read_link(b + "/link").is_err() { return Err(b + "/link should still be a symlink") }

    // The source repository is never touched by a removal.
    let source = kept(b + "/origin.git/HEAD")?

    Ok(removed && refused && source)
}
