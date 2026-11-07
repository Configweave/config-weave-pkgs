use value
use fs
use shell

// checkout_updates: the updates happened, and every refusal left its
// state exactly as setup made it.
fn git(dest: string, args: string) -> Result[string, string] {
    let out = shell::bash("git -C \"$D\" " + args, Value::Map(#{ "env": Value::Map(#{ "D": Value::String(dest) }) }))?
    if !out.success { return Err(dest + ": git " + args + " failed: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn want(dest: string, args: string, expected: string) -> Result[bool, string] {
    let got = git(dest, args)?
    if got == expected { return Ok(true) }
    Err(dest + ": git " + args + " = '" + got + "', expected '" + expected + "'")
}

fn want_file(p: string, expected: string) -> Result[bool, string] {
    let got = fs::read(p)?
    if got == expected { return Ok(true) }
    Err(p + " = '" + got + "', expected '" + expected + "'")
}

fn want_gone(p: string) -> Result[bool, string] {
    if fs::lexists(p) { return Err(p + " should not exist") }
    Ok(true)
}

fn verify(facts: Value) -> Result[bool, string] {
    let b = "/srv/cw-co/updates"
    let three = "c51c8b4293577366a769e1b4b4c3f82c74262c39"
    let two = "e9435b3d6779ea2cd83e33940c3f5755f413fdf9"
    let one = "dd9e4c0a10e31eb0bfe338f90f63d02bd69fe99e"
    let dev = "eb1f260b73e0db3a0676031ec72f464a6afc1280"

    // The remote branch moved after the clone; the checkout followed it.
    let moved = want(b + "/moved", "rev-parse HEAD", three)? &&
        want(b + "/moved", "symbolic-ref --short HEAD", "main")? &&
        want(b + "/retag", "rev-parse HEAD", one)? &&
        want(b + "/switch", "rev-parse HEAD", dev)? &&
        want(b + "/switch", "symbolic-ref --short HEAD", "dev")?

    // force discarded the edit; without force the edits survive.
    let local = want(b + "/force", "rev-parse HEAD", three)? &&
        want(b + "/force", "status --porcelain", "")? &&
        want_file(b + "/force/file.txt", "three\n")? &&
        want(b + "/dirty", "rev-parse HEAD", two)? &&
        want_file(b + "/dirty/file.txt", "local-edit\n")? &&
        want(b + "/edited", "rev-parse HEAD", three)? &&
        want_file(b + "/edited/file.txt", "local-edit\n")? &&
        want(b + "/ahead", "log -1 --format=%s", "ahead")?

    // Refused destinations are untouched; failed clones left nothing.
    let refused = want(b + "/wrong", "config --get remote.origin.url", b + "/other.git")? &&
        want_file(b + "/occupied/keep.txt", "mine\n")? &&
        want_gone(b + "/occupied/.git")? &&
        want_gone(b + "/unknown")? &&
        want_gone(b + "/nocommit")? &&
        want_gone(b + "/.nocommit.cw-clone")? &&
        want_gone(b + "/unreachable")? &&
        want_gone(b + "/.unreachable.cw-clone")?

    Ok(moved && local && refused)
}
