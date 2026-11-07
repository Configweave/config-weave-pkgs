use value
use fs
use shell

// Shared by checkout_converges (/srv/cw-svn/converge) and checkout_errors
// (/srv/cw-svn/errors). Both share a container in group "svn-checkout",
// so each tree is checked when it is present. Paths reach bash in an
// environment variable, so the dest with a space needs no quoting.

fn sh(script: string, p: string) -> Result[string, string] {
    let out = shell::bash(script, Value::Map(#{ "env": Value::Map(#{ "P": Value::String(p), "LC_ALL": Value::String("C") }) }))?
    if !out.success { return Err(p + ": " + script + " failed: " + out.stderr.trim()) }
    Ok(out.stdout.trim())
}

fn expect(what: string, got: string, want: string) -> Result[unit, string] {
    if got != want { return Err(what + ": expected '" + want + "', got '" + got + "'") }
    Ok(())
}

// svnversion of the whole working copy: "3", "1:3", "3M", "3S", ...
fn version(p: string, want: string) -> Result[unit, string] {
    expect(p + " svnversion", sh("svnversion \"$P\"", p)?, want)
}

fn url(p: string, want: string) -> Result[unit, string] {
    expect(p + " URL", sh("svn info --show-item url \"$P\"", p)?, want)
}

fn content(p: string, want: string) -> Result[unit, string] {
    expect(p, fs::read(p)?.trim(), want)
}

fn gone(p: string) -> Result[unit, string] {
    if fs::lexists(p) { return Err(p + " should not exist") }
    Ok(())
}

fn kept(p: string) -> Result[unit, string] {
    if !fs::lexists(p) { return Err(p + " should still exist") }
    Ok(())
}

// No scratch checkout left beside a dest, and the repository still at r3.
fn common(b: string) -> Result[unit, string] {
    let leftovers = sh("find \"$P\" -name '.*.cw-checkout'", b)?
    if leftovers != "" { return Err("scratch checkouts left behind: " + leftovers) }
    expect(b + "/repo youngest", sh("svnlook youngest \"$P/repo\"", b)?, "3")
}

fn verify_converges() -> Result[unit, string] {
    let b = "/srv/cw-svn/converge"
    let trunk = "file://" + b + "/repo/trunk"
    version(b + "/fresh", "3")?
    url(b + "/fresh", trunk)?
    content(b + "/fresh/file.txt", "three")?
    expect(b + "/fresh status", sh("svn status \"$P\"", b + "/fresh")?, "")?
    version(b + "/pinned one", "1")?
    content(b + "/pinned one/file.txt", "one")?
    version(b + "/new/deep/wc", "2")?
    version(b + "/behind", "3")?
    content(b + "/behind/file.txt", "three")?
    version(b + "/pinned2", "2")?
    version(b + "/at_head", "3")?
    version(b + "/edited_ok", "3M")?
    content(b + "/edited_ok/file.txt", "edited")?
    version(b + "/newer", "1")?
    content(b + "/newer/file.txt", "one")?
    version(b + "/mixed", "3")?
    content(b + "/mixed/file.txt", "three")?
    gone(b + "/remove_me")?
    gone(b + "/remove_url")?
    gone(b + "/never")?
    common(b)
}

fn verify_errors() -> Result[unit, string] {
    let b = "/srv/cw-svn/errors"
    // Refused working copies are unchanged.
    version(b + "/edited", "1M")?
    content(b + "/edited/file.txt", "edited")?
    version(b + "/unversioned", "1")?
    content(b + "/unversioned/new.txt", "mine")?
    version(b + "/switched", "3S")?
    url(b + "/wrongurl", "file://" + b + "/repo/branches/b")?
    content(b + "/plain/keep.txt", "mine")?
    if !fs::is_dir(b + "/empty") || !fs::list_dir(b + "/empty")?.is_empty() { return Err(b + "/empty should still be an empty directory") }
    content(b + "/afile", "mine")?
    version(b + "/target_a", "3")?
    kept(b + "/nest_a/sub/a.txt")?
    content(b + "/rm_edited/file.txt", "edited")?
    content(b + "/rm_unversioned/new.txt", "mine")?
    content(b + "/rm_ignored/build.o", "obj")?
    version(b + "/rm_switched", "3S")?
    url(b + "/rm_wrongurl", "file://" + b + "/repo/branches/b")?
    content(b + "/rm_plain/keep.txt", "mine")?
    kept(b + "/rm_empty")?
    version(b + "/target_b", "3")?
    kept(b + "/nest_b/sub/a.txt")?
    kept(b + "/nest_b/.svn")?
    kept("/srv")?
    if fs::read_link(b + "/link_a").is_err() { return Err(b + "/link_a should still be a symlink") }
    if fs::read_link(b + "/link_b").is_err() { return Err(b + "/link_b should still be a symlink") }
    // No rejected dest was created.
    for d in ["unknown", "unreadable", "notdir", "norepo", "at@1", "rev0", "revword", "creds", "plainpath", "option"] {
        gone(b + "/" + d)?
    }
    gone("/srv/cw-svn/escape")?
    common(b)
}

fn verify(facts: Value) -> Result[bool, string] {
    let converges = fs::is_dir("/srv/cw-svn/converge")
    let errors = fs::is_dir("/srv/cw-svn/errors")
    if !converges && !errors { return Err("neither /srv/cw-svn/converge nor /srv/cw-svn/errors exists") }
    if converges { verify_converges()? }
    if errors { verify_errors()? }
    Ok(true)
}
