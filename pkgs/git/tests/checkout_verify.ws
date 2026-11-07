use value
use fs
use shell

// checkout_converges. Assertions go through git in the checkout; paths
// reach bash in an environment variable, so the dest with a space needs
// no quoting here either.
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

fn on_branch(dest: string, branch: string, sha: string) -> Result[bool, string] {
    Ok(want(dest, "rev-parse HEAD", sha)? && want(dest, "symbolic-ref --short HEAD", branch)?)
}

// symbolic-ref fails on a detached HEAD, which is the point.
fn detached(dest: string, sha: string) -> Result[bool, string] {
    want(dest, "rev-parse HEAD", sha)?
    let out = shell::bash("git -C \"$D\" symbolic-ref -q HEAD", Value::Map(#{ "env": Value::Map(#{ "D": Value::String(dest) }) }))?
    if out.success { return Err(dest + ": HEAD should be detached, is " + out.stdout.trim()) }
    Ok(true)
}

fn verify(facts: Value) -> Result[bool, string] {
    let b = "/srv/cw-co/converge"
    let origin = b + "/origin.git"
    let three = "c51c8b4293577366a769e1b4b4c3f82c74262c39"
    let two = "e9435b3d6779ea2cd83e33940c3f5755f413fdf9"
    let one = "dd9e4c0a10e31eb0bfe338f90f63d02bd69fe99e"
    let dev = "eb1f260b73e0db3a0676031ec72f464a6afc1280"

    let cloned = on_branch(b + "/default", "main", three)? &&
        want(b + "/default", "config --get remote.origin.url", origin)? &&
        want(b + "/default", "status --porcelain", "")? &&
        on_branch(b + "/dev", "dev", dev)? &&
        on_branch(b + "/empty", "main", three)? &&
        on_branch(b + "/ready", "main", three)?

    let pinned = detached(b + "/tag v2", two)? &&
        detached(b + "/v1", one)? &&
        detached(b + "/pinned", two)?

    let shallow = on_branch(b + "/shallow", "main", three)? &&
        want(b + "/shallow", "rev-parse --is-shallow-repository", "true")? &&
        want(b + "/shallow", "rev-list --count HEAD", "1")?

    // The scratch clones are moved onto dest, never left beside it.
    let leftovers = fs::list_dir(b)?.filter(|n| n.ends_with(".cw-clone"))
    if !leftovers.is_empty() { return Err("scratch clones left behind: " + leftovers.join(", ")) }

    Ok(cloned && pinned && shallow)
}
